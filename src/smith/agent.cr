require "./llm"
require "./tools"
require "./events"
require "./config"
require "./context"
require "./hooks"

module Smith
  class Agent
    MAX_TURNS = 500

    # A model that keeps running into its output limit would otherwise cost
    # without bound.
    MAX_CONTINUATIONS = 3

    CONTINUE_TEXT = "Your previous response was cut off at the output token limit. " \
                    "Continue exactly where you left off. Do not repeat what you already wrote and do not start over."

    RETRY_SMALLER = "Your tool call was cut off at the output token limit and was discarded. " \
                    "Retry with a smaller payload — for large files, write them in multiple smaller edits."

    # A stop hook that never goes green — `make test` on a red suite — would
    # otherwise keep the loop alive until MAX_TURNS.
    MAX_STOP_CONTINUATIONS = 3

    getter provider : LLM::Provider
    getter registry : Tools::Registry
    getter model : String
    # Writable because the mode switch rebuilds it mid-session (/plan, /normal).
    property system_prompt : String
    getter messages : Array(LLM::Message)
    getter cumulative_usage : LLM::Usage
    getter listeners : Array(Events::Listener)
    getter max_context_tokens : Int32
    getter? stream : Bool
    getter hooks : Hooks::Runner

    def initialize(
      @provider : LLM::Provider,
      @registry : Tools::Registry = Tools::Registry.default,
      @model : String = Config::DEFAULT_MODEL,
      @system_prompt : String = "You are Smith, an autonomous coding agent written in Crystal.",
      messages : Array(LLM::Message)? = nil,
      @max_context_tokens : Int32 = Config::DEFAULT_MAX_CONTEXT_TOKENS,
      @stream : Bool = true,
      @hooks : Hooks::Runner = Hooks::Runner.new,
    )
      @messages = messages || Array(LLM::Message).new
      @cumulative_usage = LLM::Usage.new(0, 0, 0)
      @listeners = Array(Events::Listener).new
      @stop_requested = false
    end

    def on_event(&block : Events::Event -> Nil)
      @listeners << block
    end

    # Ends the run after the tool results of the current turn are recorded,
    # without sending them back to the provider. A tool reaches this through
    # whatever callback the CLI wired — plan mode uses it so an unapproved plan
    # never slides into execution.
    def stop! : Nil
      @stop_requested = true
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
      continuations = 0
      truncations = 0
      @stop_requested = false

      while turns < MAX_TURNS
        turns += 1

        compact_history

        request = LLM::Request.new(
          model: @model,
          system: @system_prompt,
          messages: @messages,
          tools: @registry.specs,
          stream: @stream
        )

        response = begin
          @provider.complete_streaming(request) do |delta|
            emit(Events::AssistantTextDelta.new(delta))
          end
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

        # Handled before anything else looks at the content: a response cut
        # off at the output limit is not a finished turn, and a tool call
        # inside one is not safe to run.
        if response.stop.max_tokens?
          if truncations >= MAX_CONTINUATIONS
            emit(Events::TurnError.new("Response hit the output token limit #{MAX_CONTINUATIONS + 1} times in a row; giving up."))
            return
          end

          truncations += 1
          emit(Events::ResponseContinued.new(truncations, MAX_CONTINUATIONS))
          continue_truncated(response)
          next
        end

        # Check for tool calls
        tool_uses = response.content.select { |b| b.type.tool_use? }

        if tool_uses.empty?
          # Assistant finished response without invoking tools.
          #
          # A response with no blocks at all — smaller models sometimes return
          # one, e.g. when the whole answer ends up in a reasoning field — is
          # dropped rather than recorded. It carries nothing, and it would
          # serialize to `content: null` with no tool_calls, which providers
          # reject: one such message breaks every later turn, since the whole
          # transcript is resent each time.
          if response.content.empty?
            emit(Events::EmptyResponse.new)
          else
            @messages << LLM::Message.assistant_with_blocks(response.content)
          end

          # A stop hook that blocks keeps the loop alive — that is how
          # "the tests must pass before you call it done" is expressed.
          if continuations < MAX_STOP_CONTINUATIONS
            outcome = @hooks.run(Hooks::Event::Stop, stop_payload(response))
            if outcome.blocked?
              continuations += 1
              @messages << LLM::Message.user(outcome.reason || "A stop hook asked you to keep going.")
              next
            end
          end

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

          # Where a rewind would cut the transcript: before the assistant turn
          # carrying these calls is recorded. Handed over rather than looked
          # up, so the registry stays free of transcript knowledge.
          @registry.checkpoints.try(&.current_message_index = @messages.size)

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

          # Checked after the history is complete, so the transcript stays
          # consistent — every tool_use keeps its tool_result.
          if @stop_requested
            emit(Events::TurnCompleted.new(turns))
            return
          end
        end
      end

      emit(Events::TurnError.new("Exceeded max limit of #{MAX_TURNS} turns."))
    end

    # Text can simply be carried on. A tool call cannot: half a call cannot be
    # completed, and a tool_use with no matching tool_result is rejected by
    # every provider — so the incomplete blocks are dropped and the model is
    # asked to retry smaller. That is the case that matters in practice, where
    # a large write_file payload runs out of room.
    private def continue_truncated(response : LLM::Response) : Nil
      truncated_calls = response.content.any?(&.type.tool_use?)
      keep = truncated_calls ? response.content.reject(&.type.tool_use?) : response.content

      @messages << LLM::Message.assistant_with_blocks(keep) unless keep.empty?
      @messages << LLM::Message.user(truncated_calls ? RETRY_SMALLER : CONTINUE_TEXT)
    end

    private def stop_payload(response : LLM::Response) : JSON::Any
      text = response.content.compact_map(&.text).join("\n")

      JSON.parse(JSON.build do |json|
        json.object { json.field "last_assistant_text", text }
      end)
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
      @cumulative_usage += u
    end
  end
end
