require "./llm/types"

module Smith
  # Keeps the conversation transcript from growing past the provider's context
  # window.
  #
  # The invariant everything here is built around: every `tool_use` block must
  # keep exactly one matching `tool_result`, and vice versa. Anthropic and
  # OpenAI reject a request outright if that pairing is broken, so compaction
  # may shorten content but must never orphan half a pair.
  module Context
    # What a tool result gets shortened to in stage 1.
    TRUNCATED_RESULT_BYTES = 2_000

    # Both the writer of a shortened result and whatever later has to recognise
    # one need to agree on this, so it is named rather than inlined.
    TRUNCATION_MARKER = "truncated by smith to stay within the context window"

    # Fractions of the budget: compaction acts at the trigger and compacts down
    # to the target. Expressed as fractions rather than token counts so raising
    # `max_tokens` for a wider-window model scales both.
    #
    # 80 rather than 85 because a single repo-wide grep is tens of thousands of
    # tokens, and at 85 such a result lands over the budget before compaction
    # was ever consulted. 50 rather than 60 because each compaction costs a full
    # prompt-cache creation charge on the surviving prefix — halving how often
    # it runs is worth more than the marginal fidelity.
    DEFAULT_COMPACT_AT = 0.80
    DEFAULT_COMPACT_TO = 0.50

    # Bounds on the calibration ratio. Below 1.0 is implausible for a `bytes //
    # 4` estimate; above 2.0 is a measurement error, not a context window.
    RATIO_MIN = 1.0
    RATIO_MAX = 2.0

    # How fast the calibration ratio follows what the provider reports. Low
    # enough that a single outlier cannot put a session into permanent
    # compaction.
    RATIO_SMOOTHING = 0.3

    # What a request costs and where the thresholds sit in it.
    #
    # The whole point of this being a value rather than a bare `max_tokens` is
    # that "should I act?" and "when do I stop?" are different questions.
    # Answering both with one number is what made compaction fire every turn
    # and reclaim nothing.
    struct Budget
      # The hard ceiling: what the provider will accept.
      getter max_tokens : Int32
      # Where compaction starts acting.
      getter trigger_tokens : Int32
      # What it compacts down to once it does.
      getter target_tokens : Int32
      # Everything in the request that is not the message history: system
      # prompt, project context, skills, tool definitions.
      getter overhead_tokens : Int32
      # Reported prompt tokens over estimated ones. The byte heuristic
      # undercounts; this is how much.
      getter ratio : Float64

      def initialize(
        @max_tokens : Int32,
        compact_at : Float64 = DEFAULT_COMPACT_AT,
        compact_to : Float64 = DEFAULT_COMPACT_TO,
        @overhead_tokens : Int32 = 0,
        @ratio : Float64 = 1.0,
      )
        @trigger_tokens = (@max_tokens * compact_at).to_i
        @target_tokens = (@max_tokens * compact_to).to_i
      end

      # What the request actually costs, given a raw estimate of the history.
      # Every number compaction reports is this one, so "compacted to N tokens"
      # describes the request rather than a fragment of it.
      def charged(history_tokens : Int32) : Int32
        ((history_tokens + @overhead_tokens) * @ratio).round.to_i
      end

      # The inverse: the largest raw history estimate whose charged cost still
      # fits `limit`. The stages compare against this, so none of them has to
      # redo the overhead-and-calibration arithmetic.
      def allowance(limit : Int32) : Int32
        room = (limit / @ratio).to_i - @overhead_tokens
        room < 0 ? 0 : room
      end

      def trigger_allowance : Int32
        allowance(@trigger_tokens)
      end

      def target_allowance : Int32
        allowance(@target_tokens)
      end
    end

    # Rough heuristic, not an exact count. The point is to react *before* the
    # limit, not to spend the last token of it — and `Budget#ratio` corrects the
    # systematic part of the error against what the provider reports back.
    #
    # `signature` is counted because Anthropic gets it back byte for byte
    # (see LLM::Anthropic), which makes it part of the request whether or not
    # anyone reads it.
    def self.estimate_tokens(messages : Array(LLM::Message)) : Int32
      bytes = messages.sum do |message|
        message.content.sum do |block|
          (block.text.try(&.bytesize) || 0) +
            (block.tool_args.try(&.to_json.bytesize) || 0) +
            (block.tool_name.try(&.bytesize) || 0) +
            (block.signature.try(&.bytesize) || 0)
        end
      end

      bytes // 4
    end

    # The same heuristic applied to a plain string, so a breakdown of the
    # context and the compaction decision cannot drift apart.
    def self.estimate_text_tokens(text : String) : Int32
      text.bytesize // 4
    end

    # Where the context window actually goes. Built by the caller, which is
    # the only thing that knows what went into the system prompt.
    #
    # This is also how the agent computes the reserved overhead it hands back
    # to `compact`: one class doing the arithmetic for both the breakdown the
    # user reads and the decision compaction makes, so the two cannot disagree.
    class Breakdown
      record Entry, label : String, tokens : Int32, history : Bool

      getter entries : Array(Entry)
      getter budget : Budget

      def initialize(@budget : Budget)
        @entries = Array(Entry).new
      end

      # Empty parts are kept: "Skills 0" answers "are skills eating my
      # context?", a missing line leaves the question open.
      def add(label : String, text : String) : Nil
        @entries << Entry.new(label, Context.estimate_text_tokens(text), false)
      end

      def add(label : String, messages : Array(LLM::Message)) : Nil
        @entries << Entry.new(label, Context.estimate_tokens(messages), false)
      end

      # The transcript, which is the one part compaction can shorten. Everything
      # else is overhead it has to work around.
      def add_history(label : String, messages : Array(LLM::Message)) : Nil
        @entries << Entry.new(label, Context.estimate_tokens(messages), true)
      end

      def total : Int32
        @entries.sum(&.tokens)
      end

      # A raw estimate as the provider will charge it. Identical to the input
      # until the session has learned how far the byte heuristic is off.
      def charged(tokens : Int32) : Int32
        (tokens * @budget.ratio).round.to_i
      end

      def charged_total : Int32
        charged(total)
      end

      # Everything compaction cannot touch.
      def overhead_tokens : Int32
        @entries.reject(&.history).sum(&.tokens)
      end

      def max_tokens : Int32
        @budget.max_tokens
      end

      def percent(tokens : Int32) : Int32
        return 0 if max_tokens <= 0
        (tokens * 100.0 / max_tokens).round.to_i
      end
    end

    enum Strategy
      None
      Truncated
      Summarized
      Dropped
    end

    struct Result
      getter messages : Array(LLM::Message)
      getter strategy : Strategy
      # Both are the cost of the *request*, not of the history alone.
      getter before_tokens : Int32
      getter after_tokens : Int32
      getter budget : Budget
      # Which stages actually changed something. Reported so a compaction line
      # reads as an intention rather than an accident.
      getter stages : Array(String)
      # How many messages the history lost from the front. Checkpoints record
      # absolute message indices, so anything that shortens the prefix has to
      # say by how much or a later restore cuts in the wrong place.
      getter removed_prefix : Int32

      def initialize(
        @messages,
        @strategy,
        @before_tokens,
        @after_tokens,
        @budget,
        @stages = [] of String,
        @removed_prefix = 0,
      )
      end

      def compacted? : Bool
        !@strategy.none?
      end

      def reached_target? : Bool
        @after_tokens <= @budget.target_tokens
      end

      # Over the ceiling with nothing left to reclaim. The caller stops the run
      # rather than letting the provider reject the request.
      def exhausted? : Bool
        @after_tokens > @budget.max_tokens
      end
    end

    # Brings `messages` down to `budget`'s *target* if it can, in escalating
    # stages — and does nothing at all below the trigger.
    #
    # The trigger and the target being different numbers is the whole design:
    # compacting to the first point that fits means the next assistant turn
    # pushes the history straight back over, and compaction runs again.
    #
    # `summarize` receives the prefix being dropped and returns a replacement
    # text. It is a callback rather than a provider so this whole module stays
    # testable without a network.
    def self.compact(
      messages : Array(LLM::Message),
      budget : Budget,
      &summarize : Array(LLM::Message) -> String
    ) : Result
      raw = estimate_tokens(messages)
      before = budget.charged(raw)
      stages = [] of String

      # Below the trigger the array is returned untouched — not an equal copy,
      # the same object. Rewriting the prefix invalidates the provider's prompt
      # cache, which is most of what makes compacting every turn expensive.
      return Result.new(messages, Strategy::None, before, before, budget) if before <= budget.trigger_tokens

      # A large tool set can leave no room under the target at all. Shredding
      # the entire history to reach a target that the overhead alone already
      # blew is pure loss — aim at the ceiling instead, and let the reporting
      # say the target was missed.
      target = budget.target_allowance
      target = budget.allowance(budget.max_tokens) if target.zero?

      # Not even the ceiling fits. Nothing compaction can do to the transcript
      # changes that, so it does not touch it.
      if target.zero?
        return Result.new(messages, Strategy::None, before, before, budget)
      end

      # Stage 1 — shorten tool results, oldest first. Cheap and
      # structure-preserving.
      staged = truncate_old_tool_results(messages, target)
      raw_after = estimate_tokens(staged)
      stages << "truncate" if raw_after < raw
      after = budget.charged(raw_after)
      return Result.new(staged, Strategy::Truncated, before, after, budget, stages) if raw_after <= target

      # Stage 2 — replace the oldest turns with a summary.
      cut = safe_cut_index(staged, target)
      if cut.zero?
        # Nothing further can be removed without orphaning a tool pair. Report
        # honestly rather than claiming a compaction that did not happen.
        strategy = raw_after < raw ? Strategy::Truncated : Strategy::None
        return Result.new(staged, strategy, before, after, budget, stages)
      end

      prefix = staged[0...cut]
      tail = staged[cut..]

      strategy = Strategy::Summarized
      replacement = begin
        summarize.call(prefix)
      rescue
        # Losing context beats losing the session: fall back to dropping the
        # prefix outright rather than letting the turn fail.
        strategy = Strategy::Dropped
        "#{prefix.size} earlier messages were dropped to stay within the context window. " \
        "Ask the user if you need details from before this point."
      end

      stages << (strategy.dropped? ? "drop" : "summarize")
      compacted = [LLM::Message.user("Summary of the earlier conversation: #{replacement}")] + tail

      # `cut` messages became one, so everything after shifted by cut - 1.
      Result.new(
        compacted,
        strategy,
        before,
        budget.charged(estimate_tokens(compacted)),
        budget,
        stages,
        cut - 1
      )
    end

    # Shortens tool results from oldest to newest, stopping as soon as the
    # history fits `target` — a raw history allowance, not a charged cost.
    # Stopping early is what preserves the recent results the model is actively
    # working with — but nothing is exempt, so a single oversized `cat` output
    # can still be cut down.
    #
    # Blocks are rebuilt rather than mutated because ContentBlock is read-only.
    # Carrying over tool_call_id and is_error is what keeps the pairing intact.
    private def self.truncate_old_tool_results(messages : Array(LLM::Message), target : Int32) : Array(LLM::Message)
      working = messages.dup

      each_tool_result_position(messages) do |message_index, block_index|
        return working if estimate_tokens(working) <= target

        message = working[message_index]
        block = message.content[block_index]
        text = block.text || ""
        next if text.bytesize <= TRUNCATED_RESULT_BYTES

        # Already cut once. Cutting the same head again reclaims nothing, emits
        # a nonsensical "0 KiB truncated" note, and rewrites a block the
        # provider had cached — a cache-creation charge for no gain. (Collapsing
        # these to a stub is the next step, not this one.)
        next if text.includes?(TRUNCATION_MARKER)

        rebuilt = message.content.dup
        rebuilt[block_index] = LLM::ContentBlock.tool_result(
          block.tool_call_id.not_nil!,
          truncate(text),
          block.is_error || false
        )

        working[message_index] = LLM::Message.new(message.role, rebuilt)
      end

      working
    end

    private def self.each_tool_result_position(messages : Array(LLM::Message), &)
      messages.each_with_index do |message, message_index|
        next unless message.role.tool?

        message.content.each_with_index do |block, block_index|
          yield message_index, block_index if block.type.tool_result?
        end
      end
    end

    private def self.truncate(text : String) : String
      kept = text.byte_slice(0, TRUNCATED_RESULT_BYTES)
      dropped_kib = (text.bytesize - TRUNCATED_RESULT_BYTES) // 1024
      "#{kept}\n\n[... #{dropped_kib} KiB #{TRUNCATION_MARKER} ...]"
    end

    # The lowest index of a User message such that everything from there on
    # fits `target`. User messages only ever start a turn (Agent#send), so
    # cutting there can never orphan a tool pair. Returns 0 when no such cut
    # exists — the caller then leaves the history alone rather than breaking it.
    def self.safe_cut_index(messages : Array(LLM::Message), target : Int32) : Int32
      candidates = [] of Int32
      messages.each_with_index do |message, index|
        candidates << index if message.role.user? && index > 0
      end

      candidates.each do |candidate|
        return candidate if estimate_tokens(messages[candidate..]) <= target
      end

      # Nothing fits; fall back to the newest turn boundary so at least the
      # current turn survives.
      candidates.last? || 0
    end
  end
end
