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
    # What a stale tool result gets shortened to: enough to keep a call's
    # identity, not its content. The old floor was 2 KB, which sounds modest
    # until a long session holds three hundred of them — 150k tokens, more than
    # the whole budget. At 512 bytes the same tail is ~37k, and as stubs ~6k.
    OLD_RESULT_BYTES = 512

    # Both the writer of a shortened result and whatever later has to recognise
    # one need to agree on these, so they are named rather than inlined.
    TRUNCATION_MARKER = "truncated by smith to stay within the context window"
    SUPERSEDED_MARKER = "superseded by a later identical call"

    # How many real turns are left alone. One turn is a user message and
    # everything the agent did about it, so three of them cover "read the file,
    # edit it, run the tests" whole. A constant rather than config: an extra
    # knob here buys nothing.
    RECENCY_WINDOW_TURNS = 3

    # Tools whose repeated call with identical arguments makes the earlier
    # result redundant. `bash` is deliberately absent: running `make test`
    # twice is not a duplicate, it is a before and an after, and collapsing the
    # earlier one deletes exactly the comparison the model is making. The same
    # goes for anything that observes changing state.
    SUPERSEDABLE_TOOLS = %w[read_file grep glob]

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
      messages.sum { |message| message_bytes(message) } // 4
    end

    # Bytes rather than tokens, so a running total can be kept and adjusted per
    # rewritten block without the per-message rounding drifting away from what
    # `estimate_tokens` would have said over the whole array.
    protected def self.message_bytes(message : LLM::Message) : Int32
      message.content.sum do |block|
        (block.text.try(&.bytesize) || 0) +
          (block.tool_args.try(&.to_json.bytesize) || 0) +
          (block.tool_name.try(&.bytesize) || 0) +
          (block.signature.try(&.bytesize) || 0)
      end
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

      # Stages 0-2 work on one running byte total rather than re-walking the
      # whole history per candidate, which was quadratic in the number of tool
      # results.
      working = Working.new(messages)

      # Stage 0 — drop thinking from turns that are over. Bulky, worthless to
      # anything now, and free in fidelity terms. The current turn is left
      # byte-for-byte because Anthropic validates its signatures.
      stages << "thinking" if drop_stale_thinking(working, target)

      # Stage 1 — a read superseded by a later identical read is not
      # information. Also free, and it runs before anything lossy.
      stages << "duplicates" if supersede_duplicates(working, target)

      # Stage 2 — shorten stale tool results. The first lossy stage, so it is
      # the last of the three.
      stages << "truncate" if truncate_old_tool_results(working, target)

      staged = working.messages
      raw_after = working.tokens
      after = budget.charged(raw_after)

      if raw_after <= target
        strategy = stages.empty? ? Strategy::None : Strategy::Truncated
        return Result.new(staged, strategy, before, after, budget, stages)
      end

      # Stage 3 — replace the oldest turns with a summary.
      cut = safe_cut_index(staged, target)
      if cut.zero?
        # No boundary to cut at, so the recency window is the last thing left to
        # give. One oversized `cat` inside the current turn is the case this
        # exists for: protecting the work in hand is worth less than a request
        # the provider will accept at all.
        if truncate_old_tool_results(working, target, window_turns: 0)
          stages << "truncate" unless stages.includes?("truncate")
          staged = working.messages
          after = budget.charged(working.tokens)
        end

        # Report honestly rather than claiming a compaction that did not happen.
        strategy = stages.empty? ? Strategy::None : Strategy::Truncated
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

    # The history under compaction, with a running byte total.
    #
    # The estimator used to be re-run over the whole array once per truncation
    # candidate, which is quadratic in the number of tool results. Here each
    # message is measured once and the total adjusted by the delta whenever a
    # block is rewritten. Bytes rather than tokens, so the running total agrees
    # exactly with what `estimate_tokens` would say over the finished array.
    private class Working
      getter messages : Array(LLM::Message)

      @sizes : Array(Int32)
      @bytes : Int32

      def initialize(messages : Array(LLM::Message))
        @messages = messages.dup
        @sizes = @messages.map { |message| Context.message_bytes(message) }
        @bytes = @sizes.sum
      end

      def tokens : Int32
        @bytes // 4
      end

      def fits?(target : Int32) : Bool
        tokens <= target
      end

      def replace(index : Int32, message : LLM::Message) : Nil
        size = Context.message_bytes(message)
        @bytes += size - @sizes[index]
        @sizes[index] = size
        @messages[index] = message
      end

      # Rebuilds one block of one message, keeping everything around it.
      def replace_block(message_index : Int32, block_index : Int32, block : LLM::ContentBlock) : Nil
        message = @messages[message_index]
        content = message.content.dup
        content[block_index] = block
        replace(message_index, LLM::Message.new(message.role, content, message.synthetic?))
      end
    end

    # Where the most recent `turns` real turns begin.
    #
    # Real turns: the agent injects user messages of its own — a stop-hook
    # continuation, an output-limit continuation — and counting those would let
    # three of them inside a single turn consume the whole window, so the window
    # would protect nothing.
    private def self.window_start(messages : Array(LLM::Message), turns : Int32) : Int32
      # Nothing protected: every result is a candidate.
      return messages.size if turns <= 0

      starts = [] of Int32
      messages.each_with_index do |message, index|
        starts << index if message.role.user? && !message.synthetic?
      end

      return 0 if starts.size <= turns
      starts[starts.size - turns]
    end

    # Stage 0 — thinking from turns that are over.
    #
    # It is bulky, it is worthless once the turn it belonged to is finished,
    # and dropping it costs no fidelity at all. The current turn is untouched:
    # Anthropic validates the signature on a thinking block, so a request whose
    # current turn lost one is rejected outright. That protection is a protocol
    # requirement, not a judgement about what is worth keeping — which is why it
    # is one turn here and three turns in the stages below.
    #
    # Returns whether anything changed.
    private def self.drop_stale_thinking(working : Working, target : Int32) : Bool
      protected_from = window_start(working.messages, 1)
      changed = false

      working.messages.each_with_index do |message, index|
        break if index >= protected_from
        next unless message.content.any?(&.thinking?)
        return changed if working.fits?(target)

        kept = message.content.reject(&.thinking?)
        # An assistant message with no blocks at all serializes to
        # `content: null`, which providers reject. Nothing here is worth that.
        next if kept.empty?

        working.replace(index, LLM::Message.new(message.role, kept, message.synthetic?))
        changed = true
      end

      changed
    end

    # Stage 1 — reads that a later identical read has superseded.
    #
    # Keeps the newest in full and replaces the earlier ones with a note saying
    # why they are not there, rather than deleting them: the model should
    # understand the gap. Only tools in SUPERSEDABLE_TOOLS take part, and only
    # outside the recency window.
    #
    # Returns whether anything changed.
    private def self.supersede_duplicates(working : Working, target : Int32) : Bool
      protected_from = window_start(working.messages, RECENCY_WINDOW_TURNS)
      newest = newest_call_per_key(working.messages)
      calls = tool_calls_by_id(working.messages)
      changed = false

      each_tool_result_position(working.messages) do |message_index, block_index|
        break if message_index >= protected_from
        return changed if working.fits?(target)

        block = working.messages[message_index].content[block_index]
        id = block.tool_call_id
        next if id.nil?

        call = calls[id]?
        next if call.nil? || !SUPERSEDABLE_TOOLS.includes?(call[0])
        next if newest[call]? == id

        text = block.text || ""
        stub = "[#{call[0]}: #{SUPERSEDED_MARKER}, #{text.bytesize // 1024} KiB omitted by smith]"
        next if stub.bytesize >= text.bytesize

        working.replace_block(message_index, block_index, LLM::ContentBlock.tool_result(
          id, stub, block.is_error || false
        ))
        changed = true
      end

      changed
    end

    # tool_call_id => {tool name, serialized arguments}. A tool_result carries
    # neither, so the pairing has to be read off the assistant turns.
    private def self.tool_calls_by_id(messages : Array(LLM::Message)) : Hash(String, {String, String})
      calls = Hash(String, {String, String}).new

      messages.each do |message|
        message.content.each do |block|
          next unless block.type.tool_use?
          id = block.tool_call_id
          name = block.tool_name
          next if id.nil? || name.nil?

          calls[id] = {name, block.tool_args.try(&.to_json) || ""}
        end
      end

      calls
    end

    # For each {name, arguments}, the id of the last call that made it — the one
    # whose result is still current.
    private def self.newest_call_per_key(messages : Array(LLM::Message)) : Hash({String, String}, String)
      newest = Hash({String, String}, String).new

      tool_calls_by_id(messages).each do |id, key|
        newest[key] = id
      end

      # Hash order follows insertion, which follows the transcript, so the last
      # write per key wins — but only if ids were visited in transcript order,
      # which tool_calls_by_id guarantees.
      newest
    end

    # Stage 2 — shortens stale tool results, stopping as soon as the history
    # fits `target` (a raw history allowance, not a charged cost).
    #
    # Two things differ from the version this replaces. Results inside the
    # recency window are exempt, so compaction cannot truncate the file being
    # edited out from under the model. And candidates are taken largest first
    # rather than oldest first, so reclaiming a given number of tokens mangles
    # as few results as possible.
    #
    # A result that already carries a marker collapses to a one-line stub: the
    # old behaviour kept its 2 KB head forever, which across hundreds of results
    # is an irreducible mass larger than the budget.
    #
    # Blocks are rebuilt rather than mutated because ContentBlock is read-only.
    # Carrying over tool_call_id and is_error is what keeps the pairing intact.
    private def self.truncate_old_tool_results(working : Working, target : Int32, window_turns : Int32 = RECENCY_WINDOW_TURNS) : Bool
      protected_from = window_start(working.messages, window_turns)

      candidates = [] of {Int32, Int32, Int32}
      each_tool_result_position(working.messages) do |message_index, block_index|
        break if message_index >= protected_from

        size = working.messages[message_index].content[block_index].text.try(&.bytesize) || 0
        candidates << {size, message_index, block_index}
      end

      candidates.sort_by! { |candidate| -candidate[0] }
      changed = false

      candidates.each do |(_, message_index, block_index)|
        return changed if working.fits?(target)

        block = working.messages[message_index].content[block_index]
        text = block.text || ""
        shortened = shorten(text)
        next if shortened.bytesize >= text.bytesize

        working.replace_block(message_index, block_index, LLM::ContentBlock.tool_result(
          block.tool_call_id.not_nil!, shortened, block.is_error || false
        ))
        changed = true
      end

      changed
    end

    private def self.each_tool_result_position(messages : Array(LLM::Message), &)
      messages.each_with_index do |message, message_index|
        next unless message.role.tool?

        message.content.each_with_index do |block, block_index|
          yield message_index, block_index if block.type.tool_result?
        end
      end
    end

    # Reached once: keep a head, so the call still has an identity. Reached
    # twice, or already superseded: keep only the note.
    private def self.shorten(text : String) : String
      if text.includes?(TRUNCATION_MARKER) || text.includes?(SUPERSEDED_MARKER)
        return "[#{text.bytesize // 1024} KiB #{TRUNCATION_MARKER}]"
      end

      return text if text.bytesize <= OLD_RESULT_BYTES

      kept = text.byte_slice(0, OLD_RESULT_BYTES)
      dropped_kib = (text.bytesize - OLD_RESULT_BYTES) // 1024
      "#{kept}\n\n[... #{dropped_kib} KiB #{TRUNCATION_MARKER} ...]"
    end

    # The lowest index of a User message such that everything from there on
    # fits `target`. User messages only ever start a turn (Agent#send), so
    # cutting there can never orphan a tool pair. Returns 0 when no such cut
    # exists — the caller then leaves the history alone rather than breaking it.
    def self.safe_cut_index(messages : Array(LLM::Message), target : Int32) : Int32
      candidates = [] of Int32
      messages.each_with_index do |message, index|
        # Synthetic messages are skipped: cutting just before an agent-injected
        # continuation leaves it referring to a response that is no longer there.
        candidates << index if message.role.user? && !message.synthetic? && index > 0
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
