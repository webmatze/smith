require "./app"
require "../output"
require "../pricing"
require "../version"

module Smith::UI
  # An IO that turns whatever is written to it into notice lines in the app —
  # the seam for components that still speak IO (the Renderer contract's
  # prompt_io). Writes are line-buffered.
  class NoticeIO < IO
    def initialize(@app : App)
      @pending = ""
    end

    def read(slice : Bytes)
      raise IO::Error.new("NoticeIO is write-only")
    end

    def write(slice : Bytes) : Nil
      @pending += String.new(slice)
      while index = @pending.index('\n')
        line = @pending[0...index]
        @pending = @pending[(index + 1)..]
        @app.notice(line) unless line.strip.empty?
      end
    end
  end

  # The third Renderer: turns the event stream into blocks for the fullscreen
  # app instead of plain print lines or JSON.
  class TuiRenderer < Smith::Output::Renderer
    getter app : App

    @assistant : AssistantBlock? = nil
    @thinking : ThinkingBlock? = nil

    def initialize(@app : App)
      @tools = Hash(String, ToolBlock).new
      @prompt_io = NoticeIO.new(@app)
    end

    def prompt_io : IO
      @prompt_io
    end

    def banner(provider : String, model : String, skills : Array(String)) : Nil
      lines = Array(StyledLine).new
      lines << [
        Span.new("⚒ ", Style.new(fg: Palette::WARN)),
        Span.new("smith", Style.new(bold: true)),
        Span.new(" v#{Smith::VERSION}", Style.new(fg: Palette::INFO)),
      ]
      lines << [Span.new("#{provider} · #{model}", Style.new(fg: Palette::INFO, dim: true))]
      unless skills.empty?
        lines << [Span.new("skills: #{skills.join(", ")}", Style.new(fg: Palette::INFO, dim: true))]
      end
      @app.notice(lines)
    end

    def handle(event : Smith::Events::Event) : Nil
      case event
      when Smith::Events::AssistantTextDelta
        open_assistant.buffer += event.text
        app.mark_dirty
      when Smith::Events::AssistantText
        @answer << event.text
        close_assistant
      when Smith::Events::ThinkingDelta
        open_thinking.buffer += event.text
        app.mark_dirty
      when Smith::Events::ThinkingBlock
        close_thinking
        if event.redacted?
          app.notice("✻ (redacted thinking)", Style.new(fg: Palette::THINKING, dim: true))
        end
      when Smith::Events::ToolStart
        close_assistant
        block = ToolBlock.new(
          event.tool_call_id,
          event.tool_name,
          ToolBlock.summarize(event.args)
        )
        @tools[event.tool_call_id] = block
        app.add_block(block)
      when Smith::Events::ToolFinished
        if block = @tools[event.tool_call_id]?
          block.status = event.is_error ? ToolBlock::Status::Failed : ToolBlock::Status::Done
          block.result = event.result
        end
        app.mark_dirty
      when Smith::Events::TodosUpdated
        if event.items.empty?
          app.notice("☰ Todos cleared", Style.new(fg: Palette::INFO))
        else
          app.add_block(TodosBlock.new(event.items), finalize: true)
        end
      when Smith::Events::BashJobStarted
        app.notice("⏱ background job #{event.id} started: #{event.command}", Style.new(fg: Palette::INFO))
      when Smith::Events::BashJobExited
        app.notice("⏱ background job #{event.id} #{event.status}", Style.new(fg: Palette::INFO))
      when Smith::Events::ResponseContinued
        app.notice("↩ output limit hit — continuing (#{event.attempt}/#{event.limit})", Style.new(fg: Palette::WARN))
      when Smith::Events::EmptyResponse
        app.notice("⚠ the model returned an empty response", Style.new(fg: Palette::WARN))
      when Smith::Events::HookFired
        if event.blocked?
          app.notice("🪝 #{event.hook_event.to_key} blocked: #{event.command}", Style.new(fg: Palette::ERROR))
        else
          app.notice("🪝 #{event.hook_event.to_key}: #{event.command}", Style.new(fg: Palette::INFO, dim: true))
        end
      when Smith::Events::PlanPresented
        # Shown here in the scrollback; the interactive gate only asks.
        lines = Array(StyledLine).new
        lines << [Span.new("📋 Plan", Style.new(bold: true))]
        lines.concat(Markdown.render(event.plan, 1000))
        app.notice(lines)
      when Smith::Events::ModeChanged
        app.mode = event.mode
        text = event.mode.plan? ? "🧭 plan mode — research only, /normal to leave" : "🧭 normal mode"
        style = event.mode.plan? ? Style.new(fg: Palette::MODE_PLAN) : Style.new(fg: Palette::INFO)
        app.notice(text, style)
      when Smith::Events::FilesMentioned
        event.files.each do |file|
          size = file.lines.zero? ? "directory" : "#{file.lines} lines"
          size += ", truncated" if file.truncated?
          app.notice("📎 #{file.path} (#{size})", Style.new(fg: Palette::INFO, dim: true))
        end
        event.skipped.each do |skip|
          app.notice("⚠ #{skip.path} — #{skip.reason}", Style.new(fg: Palette::WARN))
        end
      when Smith::Events::HistoryCompacted
        stages = event.stages.empty? ? "" : " · #{event.stages.join(", ")}"
        app.notice("🗜 context compacted (#{event.strategy}): ~#{event.before_tokens} → ~#{event.after_tokens} " \
                   "tokens, #{event.reclaimed_percent}% of the budget reclaimed#{stages}",
          Style.new(fg: Palette::INFO, dim: true))
        unless event.reached_target?
          app.notice("⚠ could not reach the ~#{event.target_tokens} token target — consider a fresh session",
            Style.new(fg: Palette::WARN))
        end
      when Smith::Events::ContextExhausted
        # Not budget_exceeded?: that means "you spent your money", and its exit
        # code says so. Running out of window is a different failure.
        @failed = true
        app.notice("🧱 context exhausted: ~#{event.estimated_tokens} tokens against a #{event.budget_tokens} " \
                   "budget — start a fresh session",
          Style.new(fg: Palette::ERROR))
      when Smith::Events::BudgetExceeded
        @budget_exceeded = true
        app.notice("💸 budget spent: #{Smith::Pricing.format(event.spent_usd)} of #{Smith::Pricing.format(event.limit_usd)} — stopping",
          Style.new(fg: Palette::ERROR))
      when Smith::Events::UsageUpdated
        app.usage_text = short_tokens(event.usage.total_tokens)
        app.mark_dirty
      when Smith::Events::TurnCompleted
        app.activity = ""
        app.mark_dirty
      when Smith::Events::TurnError
        @failed = true
        app.notice("❌ #{event.error}", Style.new(fg: Palette::ERROR, bold: true))
      end
    end

    def finish(usage : Smith::LLM::Usage, cost : Float64? = nil) : Nil
      cached = usage.cached_tokens.zero? ? "" : " (#{usage.cached_tokens} cached)"
      app.notice("📊 #{short_tokens(usage.prompt_tokens)} prompt#{cached} + #{short_tokens(usage.completion_tokens)} completion · #{Smith::Pricing.format(cost)}",
        Style.new(fg: Palette::INFO, dim: true))
    end

    # `answer` comes from the base Renderer; deltas feed @answer there too.
    private def open_assistant : AssistantBlock
      @assistant ||= (app.add_block(AssistantBlock.new).as(AssistantBlock))
    end

    private def close_assistant : Nil
      if block = @assistant
        block.live = false
        @assistant = nil
        app.mark_dirty
      end
    end

    private def open_thinking : ThinkingBlock
      @thinking ||= (app.add_block(ThinkingBlock.new).as(ThinkingBlock))
    end

    private def close_thinking : Nil
      if block = @thinking
        block.live = false
        @thinking = nil
        app.mark_dirty
      end
    end

    private def short_tokens(count : Int32) : String
      if count >= 1_000_000
        "#{"%.1f" % (count / 1_000_000.0)}M tok"
      elsif count >= 10_000
        "#{"%.1f" % (count / 1_000.0)}k tok"
      else
        "#{count} tok"
      end
    end
  end
end
