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

    # Rough heuristic, not an exact count. The point is to react *before* the
    # limit, not to spend the last token of it.
    def self.estimate_tokens(messages : Array(LLM::Message)) : Int32
      bytes = messages.sum do |message|
        message.content.sum do |block|
          (block.text.try(&.bytesize) || 0) +
            (block.tool_args.try(&.to_json.bytesize) || 0) +
            (block.tool_name.try(&.bytesize) || 0)
        end
      end

      bytes // 4
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
      getter before_tokens : Int32
      getter after_tokens : Int32

      def initialize(@messages, @strategy, @before_tokens, @after_tokens)
      end

      def compacted? : Bool
        !@strategy.none?
      end
    end

    # Brings `messages` under `max_tokens` if it can, in two escalating stages.
    #
    # `summarize` receives the prefix being dropped and returns a replacement
    # text. It is a callback rather than a provider so this whole module stays
    # testable without a network.
    def self.compact(
      messages : Array(LLM::Message),
      max_tokens : Int32,
      &summarize : Array(LLM::Message) -> String
    ) : Result
      before = estimate_tokens(messages)
      return Result.new(messages, Strategy::None, before, before) if before <= max_tokens

      # Stage 1 — shorten tool results, oldest first. Cheap and
      # structure-preserving.
      staged = truncate_old_tool_results(messages, max_tokens)
      after = estimate_tokens(staged)
      return Result.new(staged, Strategy::Truncated, before, after) if after <= max_tokens

      # Stage 2 — replace the oldest turns with a summary.
      cut = safe_cut_index(staged, max_tokens)
      if cut.zero?
        # Nothing further can be removed without orphaning a tool pair. Report
        # honestly rather than claiming a compaction that did not happen.
        strategy = after < before ? Strategy::Truncated : Strategy::None
        return Result.new(staged, strategy, before, after)
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

      compacted = [LLM::Message.user("Summary of the earlier conversation: #{replacement}")] + tail
      Result.new(compacted, strategy, before, estimate_tokens(compacted))
    end

    # Convenience wrapper for callers that have no summarizer available.
    def self.compact(messages : Array(LLM::Message), max_tokens : Int32) : Result
      compact(messages, max_tokens) { |_| raise "no summarizer configured" }
    end

    # Shortens tool results from oldest to newest, stopping as soon as the
    # history fits. Stopping early is what preserves the recent results the
    # model is actively working with — but nothing is exempt, so a single
    # oversized `cat` output can still be cut down.
    #
    # Blocks are rebuilt rather than mutated because ContentBlock is read-only.
    # Carrying over tool_call_id and is_error is what keeps the pairing intact.
    private def self.truncate_old_tool_results(messages : Array(LLM::Message), max_tokens : Int32) : Array(LLM::Message)
      working = messages.dup

      each_tool_result_position(messages) do |message_index, block_index|
        return working if estimate_tokens(working) <= max_tokens

        message = working[message_index]
        block = message.content[block_index]
        text = block.text || ""
        next if text.bytesize <= TRUNCATED_RESULT_BYTES

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
      "#{kept}\n\n[... #{dropped_kib} KiB truncated by smith to stay within the context window ...]"
    end

    # The lowest index of a User message such that everything from there on
    # fits the budget. User messages only ever start a turn (Agent#send), so
    # cutting there can never orphan a tool pair. Returns 0 when no such cut
    # exists — the caller then leaves the history alone rather than breaking it.
    def self.safe_cut_index(messages : Array(LLM::Message), max_tokens : Int32) : Int32
      candidates = [] of Int32
      messages.each_with_index do |message, index|
        candidates << index if message.role.user? && index > 0
      end

      candidates.each do |candidate|
        return candidate if estimate_tokens(messages[candidate..]) <= max_tokens
      end

      # Nothing fits; fall back to the newest turn boundary so at least the
      # current turn survives.
      candidates.last? || 0
    end
  end
end
