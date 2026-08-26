require "./llm"
require "./tools"
require "./events"
require "./config"
require "./context"
require "./transcript_log"
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
    getter context_settings : Config::ContextSettings
    # Reported prompt tokens over estimated ones. Persisted with the session so
    # the first turn after a resume is not blind about a 100k history.
    property context_ratio : Float64
    getter? stream : Bool
    getter hooks : Hooks::Runner

    # What compaction has done to this session so far. `smith context` reports
    # it; a session read back from disk has no such history to report.
    getter compactions : Int32 = 0
    getter last_compaction : Context::Strategy? = nil

    def initialize(
      @provider : LLM::Provider,
      @registry : Tools::Registry = Tools::Registry.default,
      @model : String = Config::DEFAULT_MODEL,
      @system_prompt : String = "You are Smith, an autonomous coding agent written in Crystal.",
      messages : Array(LLM::Message)? = nil,
      @context_settings : Config::ContextSettings = Config::ContextSettings.new,
      @context_ratio : Float64 = 1.0,
      @transcript_log : TranscriptLog? = nil,
      @stream : Bool = true,
      @hooks : Hooks::Runner = Hooks::Runner.new,
      @thinking_effort : String? = nil,
      @thinking_budget : Int32? = nil,
      @cost_limit_usd : Float64? = nil,
      @rates : Pricing::Rates? = nil,
    )
      @messages = messages || Array(LLM::Message).new
      # Whatever the agent starts with is already on the record: a resumed
      # session was logged as it happened, or seeded by the caller.
      @transcript_logged = @messages.size
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

    def send(user_text : String, attachments : Array(LLM::ContentBlock) = Array(LLM::ContentBlock).new) : Nil
      blocks = [LLM::ContentBlock.text(user_text)] of LLM::ContentBlock
      blocks.concat(attachments.map { |block| carryable(block) })

      @messages << LLM::Message.new(LLM::Role::User, blocks)
      run_loop
    ensure
      # The last turn's messages arrive after the final compaction check, so
      # without this they would never reach the record.
      flush_transcript_log
    end

    # An attachment this provider cannot take is described rather than
    # dropped. Dropping it would leave the model answering a question about a
    # picture it was never shown and with no way to know that; a line of text
    # says what was attached, so it can ask for another way in.
    private def carryable(block : LLM::ContentBlock) : LLM::ContentBlock
      case block.type
      when LLM::ContentBlock::BlockType::Image
        return block if @provider.supports_images?
        LLM::ContentBlock.text(
          "[#{block.media_label} (#{block.media_type}) was attached, but the #{@provider.name} " \
          "provider cannot receive images.]"
        )
      when LLM::ContentBlock::BlockType::Document
        return block if @provider.supports_documents?
        LLM::ContentBlock.text(
          "[#{block.media_label} (#{block.media_type}) was attached, but the #{@provider.name} " \
          "provider cannot read documents. Extract its text with a command-line tool via `bash` " \
          "— `pdftotext` for a PDF — and read that instead.]"
        )
      else
        block
      end
    end

    # Everything appended since the last flush. Compaction is the only thing
    # that removes messages and it flushes before it runs, so between flushes
    # the array only ever grows at the end.
    private def flush_transcript_log : Nil
      log = @transcript_log
      return if log.nil? || @transcript_logged >= @messages.size

      log.append(@messages[@transcript_logged..])
      @transcript_logged = @messages.size
    end

    # The amount spent when it has reached the limit, nil otherwise. Without
    # rates there is nothing to enforce — the CLI warns about that rather than
    # letting a run believe it is capped.
    private def over_budget? : Float64?
      limit = @cost_limit_usd
      rates = @rates
      return nil if limit.nil? || rates.nil?

      spent = Pricing.cost(@cumulative_usage, rates)
      spent >= limit ? spent : nil
    end

    private def run_loop
      turns = 0
      continuations = 0
      truncations = 0
      @stop_requested = false

      while turns < MAX_TURNS
        turns += 1

        # A request that cannot be brought under the ceiling will be rejected by
        # the provider anyway; stopping here says why, and costs nothing.
        return if compact_history

        request = LLM::Request.new(
          model: @model,
          system: @system_prompt,
          messages: @messages,
          tools: @registry.specs,
          stream: @stream,
          thinking_effort: @thinking_effort,
          thinking_budget: @thinking_budget
        )

        response = begin
          @provider.on_thinking = ->(chunk : String) { emit(Events::ThinkingDelta.new(chunk)) }
          @provider.complete_streaming(request) do |delta|
            emit(Events::AssistantTextDelta.new(delta))
          end
        rescue ex : Exception
          emit(Events::TurnError.new("Provider completion failed: #{ex.message}"))
          return
        end

        if usage = response.usage
          update_usage(usage)
          # Done here, before the response is appended, so @messages is still
          # exactly what the reported prompt tokens were charged for.
          recalibrate(usage)
          emit(Events::UsageUpdated.new(@cumulative_usage))
        end

        # Checked after the response rather than before the request: the cost
        # of a turn is only known once it is billed, and stopping here means
        # the answer just paid for is still delivered.
        if spent = over_budget?
          emit(Events::BudgetExceeded.new(spent_usd: spent, limit_usd: @cost_limit_usd.not_nil!))
          return
        end

        # Emit text blocks to listeners
        response.content.each do |block|
          if block.type.text? && (txt = block.text)
            emit(Events::AssistantText.new(txt))
          elsif block.type.thinking? && (txt = block.text)
            emit(Events::ThinkingBlock.new(txt))
          elsif block.type.redacted_thinking?
            # The content is encrypted; only its presence is reportable.
            emit(Events::ThinkingBlock.new("", redacted: true))
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
              @messages << LLM::Message.user(outcome.reason || "A stop hook asked you to keep going.", synthetic: true)
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
          @registry.checkpoints.try(&.current_message_id = @messages.last?.try(&.id))

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
      @messages << LLM::Message.user(truncated_calls ? RETRY_SMALLER : CONTINUE_TEXT, synthetic: true)
    end

    private def stop_payload(response : LLM::Response) : JSON::Any
      text = response.content.compact_map(&.text).join("\n")

      JSON.parse(JSON.build do |json|
        json.object { json.field "last_assistant_text", text }
      end)
    end

    # Where the context window goes, counted the way compaction counts it.
    # `smith context` renders this; compaction reads `overhead_tokens` off it.
    # One computation rather than two is what keeps the breakdown and the
    # compaction decision from disagreeing.
    def breakdown : Context::Breakdown
      result = Context::Breakdown.new(context_budget)
      result.add("System prompt", @system_prompt)
      result.add("Tool definitions", @registry.specs.to_json)
      result.add_history("Messages", @messages)
      result
    end

    # Rebuilt per turn rather than cached: @system_prompt is rewritten by the
    # mode switch, and @registry grows when an MCP server connects. A stale
    # overhead is a silent overflow, and recomputing it is one `to_json`.
    private def context_budget(overhead_tokens : Int32 = 0) : Context::Budget
      @context_settings.budget(overhead_tokens, @context_ratio)
    end

    # Runs before every request, so the history can never outgrow the window
    # mid-conversation. Below the trigger this is a no-op and leaves @messages
    # byte-identical — rewriting the prefix would cost a full prompt-cache
    # creation charge on every turn.
    private def compact_history
      # Before anything is shortened: what compaction is about to discard is
      # exactly what the record exists to keep.
      flush_transcript_log

      parts = breakdown
      budget = context_budget(parts.overhead_tokens)

      result = Context.compact(@messages, budget) do |prefix|
        summarize_prefix(prefix)
      end

      if result.compacted?
        @messages = result.messages
        # The surviving suffix is already on the record and the summary is a
        # compaction artefact, not history — so nothing here is owed to it.
        @transcript_logged = @messages.size
        @compactions += 1
        @last_compaction = result.strategy

        emit(Events::HistoryCompacted.new(
          result.before_tokens,
          result.after_tokens,
          result.strategy.to_s.downcase,
          budget.target_tokens,
          budget.max_tokens,
          result.stages
        ))
      end

      return false unless result.exhausted?

      emit(Events::ContextExhausted.new(
        result.after_tokens,
        budget.max_tokens,
        result.before_tokens - result.after_tokens
      ))
      true
    end

    # How far off the byte heuristic is, learned from what the provider says it
    # actually charged. Smoothed so one outlier cannot put a session into
    # permanent compaction, and clamped because anything outside the bounds is
    # a measurement error rather than a context window.
    private def recalibrate(usage : LLM::Usage) : Nil
      estimated = breakdown.total
      reported = usage.billed_prompt_tokens
      return if estimated <= 0 || reported <= 0

      observed = reported / estimated.to_f
      blended = @context_ratio + (observed - @context_ratio) * Context::RATIO_SMOOTHING
      @context_ratio = blended.clamp(Context::RATIO_MIN, Context::RATIO_MAX)
    end

    # A separate, tool-free call so summarizing cannot itself trigger tool use
    # or drag the main conversation's history along.
    private def summarize_prefix(prefix : Array(LLM::Message)) : String
      transcript = prefix.map do |message|
        # Thinking is dropped rather than summarised: it is bulky, worthless to
        # a summary, and the turns it belonged to are being replaced anyway, so
        # no signature is left dangling.
        text = message.content.reject(&.thinking?).compact_map(&.text).join("\n")
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
