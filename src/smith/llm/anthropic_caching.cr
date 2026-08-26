require "json"
require "./types"

module Smith::LLM
  # The parts of Anthropic prompt caching that do not depend on the wire
  # format, shared by the two providers that can reach an Anthropic model:
  # `Anthropic` directly, `OpenRouter` when it routes to one.
  #
  # What is shared is the *policy* — which message to mark, and what a marker
  # looks like. The *placement* is not, and cannot be: Anthropic speaks the
  # Messages schema, OpenRouter the OpenAI one, and the same breakpoint lands
  # in a differently shaped object in each. Trying to share that too would
  # produce a builder that knows both schemas and serves neither.
  module AnthropicCaching
    # The marker itself. Two lines, but two lines that have to be spelled
    # identically in both providers or one of them silently caches nothing.
    private def cache_control(json : JSON::Builder) : Nil
      json.field "cache_control" do
        json.object { json.field "type", "ephemeral" }
      end
    end

    # The index of the message to mark, or nil when there is nothing worth
    # marking yet.
    #
    # The *second-to-last* user turn, not the last: the newest one changes with
    # the next request, so a breakpoint there would write a cache nothing ever
    # reads. Tool results count — Anthropic receives them as user turns.
    #
    # Note this is invalidated whenever Context.compact rewrites the prefix.
    # That is unavoidable and correct; the system prompt and tools stay cached
    # either way.
    private def transcript_breakpoint(messages : Array(Message)) : Int32?
      user_turns = Array(Int32).new
      messages.each_with_index do |msg, index|
        user_turns << index if msg.role.user? || msg.role.tool?
      end
      return nil if user_turns.size < 2

      user_turns[-2]
    end

    # Usage from an OpenAI-shaped `usage` object that carries Anthropic cache
    # counters — which is what OpenRouter returns on an Anthropic route.
    #
    # Two things differ from the direct Anthropic route. The counters are named
    # the OpenAI way and live one level down, under `prompt_tokens_details`.
    # And `prompt_tokens` here is the *whole* prompt, cached part included,
    # where smith's `Usage#prompt_tokens` is the uncached remainder and the
    # cost model adds the cache counters on top of it. Passing the number
    # through as it arrives would bill the cached prefix twice — hence the
    # subtraction, clamped because a provider that reports an inconsistent
    # triple must not turn into a negative token count.
    def self.usage(json : JSON::Any) : Usage
      prompt = json["prompt_tokens"]?.try(&.as_i?) || 0
      completion = json["completion_tokens"]?.try(&.as_i?) || 0
      total = json["total_tokens"]?.try(&.as_i?) || (prompt + completion)

      details = json["prompt_tokens_details"]?.try(&.as_h?)
      creation = details.try(&.["cache_write_tokens"]?).try(&.as_i?) || 0
      read = details.try(&.["cached_tokens"]?).try(&.as_i?) || 0

      Usage.new(
        prompt_tokens: {prompt - creation - read, 0}.max,
        completion_tokens: completion,
        total_tokens: total,
        cache_creation_tokens: creation,
        cache_read_tokens: read
      )
    end
  end
end
