require "./llm"
require "./tools"
require "./events"
require "./config"
require "./context"

module Smith
  class Agent
    MAX_TURNS = 500

    getter provider : LLM::Provider
    getter registry : Tools::Registry
    getter model : String
    getter system_prompt : String
    getter messages : Array(LLM::Message)
    getter cumulative_usage : LLM::Usage
    getter listeners : Array(Events::Listener)
    getter max_context_tokens : Int32

    def initialize(
      @provider : LLM::Provider,
      @registry : Tools::Registry = Tools::Registry.default,
      @model : String = Config::DEFAULT_MODEL,
      @system_prompt : String = "You are Smith, an autonomous coding agent written in Crystal.",
      messages : Array(LLM::Message)? = nil,
      @max_context_tokens : Int32 = Config::DEFAULT_MAX_CONTEXT_TOKENS,
    )
      @messages = messages || Array(LLM::Message).new
      @cumulative_usage = LLM::Usage.new(0, 0, 0)
      @listeners = Array(Events::Listener).new
    end

    def on_event(&block : Events::Event -> Nil)
      @listeners << block
    end

    private def emit(event : Events::Event)
      @listeners.each(&.call(event))
    end

    def send(user_text : String) : Nil
      @messages << LLM::Message.user(user_text)
      run_loop
    end

    private def run_loop
      turns = 0

      while turns < MAX_TURNS
        turns += 1

        compact_history

        request = LLM::Request.new(
          model: @model,
          system: @system_prompt,
          messages: @messages,
          tools: @registry.specs
        )

        response = begin
          @provider.complete(request)
        rescue ex : Exception
          emit(Events::TurnError.new("Provider completion failed: #{ex.message}"))
          return
        end

        if usage = response.usage
          update_usage(usage)
          emit(Events::UsageUpdated.new(@cumulative_usage))
        end

        # Emit text blocks to listeners
        response.content.each do |block|
          if block.type.text? && (txt = block.text)
            emit(Events::AssistantText.new(txt))
          end
        end

        # Check for tool calls
        tool_uses = response.content.select { |b| b.type.tool_use? }

        if tool_uses.empty?
          # Assistant finished response without invoking tools
          @messages << LLM::Message.assistant_with_blocks(response.content)
          emit(Events::TurnCompleted.new(turns))
          return
        else
          # Assistant requested tool executions
          call_requests = tool_uses.map do |tu|
            call_id = tu.tool_call_id.not_nil!
            tool_name = tu.tool_name.not_nil!
            args = tu.tool_args || JSON.parse("{}")

            emit(Events::ToolStart.new(call_id, tool_name, args))
            Tools::CallRequest.new(call_id, tool_name, args)
          end

          # Execute tools concurrently or serially via registry
          tool_result_blocks = @registry.execute_calls(call_requests)

          tool_result_blocks.each do |result_block|
            call_id = result_block.tool_call_id.not_nil!
            res_text = result_block.text || ""
            is_err = result_block.is_error || false

            # Find matching tool name for event
            matching_tu = tool_uses.find { |tu| tu.tool_call_id == call_id }
            name = matching_tu ? (matching_tu.tool_name || "unknown") : "unknown"

            emit(Events::ToolFinished.new(call_id, name, res_text, is_err))
          end

          # Append assistant response & tool results atomically to history
          @messages << LLM::Message.assistant_with_blocks(response.content)
          @messages << LLM::Message.tool_results(tool_result_blocks)
        end
      end

      emit(Events::TurnError.new("Exceeded max limit of #{MAX_TURNS} turns."))
    end

    # Runs before every request, so the history can never outgrow the window
    # mid-conversation. Below the budget this is a no-op and leaves @messages
    # byte-identical.
    private def compact_history
      result = Context.compact(@messages, @max_context_tokens) do |prefix|
        summarize_prefix(prefix)
      end

      return unless result.compacted?

      @messages = result.messages
      emit(Events::HistoryCompacted.new(
        result.before_tokens,
        result.after_tokens,
        result.strategy.to_s.downcase
      ))
    end

    # A separate, tool-free call so summarizing cannot itself trigger tool use
    # or drag the main conversation's history along.
    private def summarize_prefix(prefix : Array(LLM::Message)) : String
      transcript = prefix.map do |message|
        text = message.content.compact_map(&.text).join("\n")
        "#{message.role}: #{text}"
      end.join("\n\n")

      response = @provider.complete(LLM::Request.new(
        model: @model,
        system: "You compress conversation transcripts. Reply with a dense factual summary " \
                "covering decisions made, files touched and open questions. No preamble.",
        messages: [LLM::Message.user(transcript)]
      ))

      summary = response.content.compact_map(&.text).join("\n").strip
      raise "empty summary" if summary.empty?
      summary
    end

    private def update_usage(u : LLM::Usage)
      @cumulative_usage = LLM::Usage.new(
        @cumulative_usage.prompt_tokens + u.prompt_tokens,
        @cumulative_usage.completion_tokens + u.completion_tokens,
        @cumulative_usage.total_tokens + u.total_tokens
      )
    end
  end
end
