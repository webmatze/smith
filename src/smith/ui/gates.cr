require "./app"
require "../tools"
require "../plan"
require "../trust"

module Smith::UI
  # The approval gate for fullscreen mode: a modal panel with the call's
  # summary and three keys, answered without ever touching plain stdin.
  class TuiApprover < Smith::Tools::Approver
    # How much of the call the panel shows before it starts eliding.
    SUMMARY_LINES = 8

    getter allowlist : Array(String)

    def initialize(
      @app : App,
      @allowlist : Array(String) = Array(String).new,
      @rules : Smith::Tools::RuleSet = Smith::Tools::RuleSet.new,
    )
      @remembered = Array(Smith::Tools::Rule).new
    end

    def approve?(tool : Smith::Tools::Tool, call : Smith::Tools::CallRequest) : Bool
      return true if remembered?(tool, call)
      return true if tool.name == "bash" && allowlisted_command?(call)

      ask(tool, call)
    end

    private def remembered?(tool : Smith::Tools::Tool, call : Smith::Tools::CallRequest) : Bool
      @remembered.any? { |rule| rule.matches?(tool.name, call.args, @rules.project_dir, all: true) }
    end

    private def allowlisted_command?(call : Smith::Tools::CallRequest) : Bool
      command = call.args["command"]?.try(&.as_s?)
      return false if command.nil?

      Smith::Tools::AllowList.allows?(command, @allowlist)
    end

    private def ask(tool : Smith::Tools::Tool, call : Smith::Tools::CallRequest) : Bool
      suggestion = @rules.suggest(tool.name, call.args)

      body = Array(StyledLine).new
      body << [
        Span.new("Tool    ", Style.new(fg: Palette::INFO)),
        Span.new(tool.name, Style.new(bold: true)),
      ]
      # Wrapped to the real terminal width, and capped: the panel shares the
      # screen with whatever is still running above it, and a call whose
      # arguments run to hundreds of lines must not push the question itself
      # out of view.
      width, _ = @app.terminal.size
      wrapped = LineUtil.wrap([Span.new(summarize(call))], {width - 8, 20}.max)
      if wrapped.size > SUMMARY_LINES
        dropped = wrapped.size - SUMMARY_LINES
        wrapped = wrapped.first(SUMMARY_LINES)
        wrapped << [Span.new("… #{dropped} more line#{dropped == 1 ? "" : "s"}", Style.new(dim: true))]
      end

      wrapped.each_with_index do |line, i|
        prefix = i.zero? ? [Span.new("Summary ", Style.new(fg: Palette::INFO))] : [Span.new("        ")]
        body << prefix + line
      end

      answer = @app.modal(
        "Approval required",
        body,
        [{'y', "allow once"}, {'n', "deny"}, {'a', "always allow `#{suggestion}`"}],
        ['y', 'n', 'a']
      )

      case answer
      when 'y'
        true
      when 'a'
        if rule = Smith::Tools::Rule.parse(suggestion)
          @remembered << rule
        end
        true
      else
        false
      end
    end

    private def summarize(call : Smith::Tools::CallRequest) : String
      if command = call.args["command"]?.try(&.as_s?)
        "$ #{command}"
      elsif path = call.args["path"]?.try(&.as_s?)
        "Path: #{path}"
      else
        call.args.to_json
      end
    end
  end

  # The plan-mode gate for fullscreen mode: the plan text is already in the
  # scrollback (the renderer printed it), so the modal only asks.
  class TuiPlanGate < Smith::PlanGate
    def initialize(@app : App)
    end

    def review(plan : String) : Smith::PlanVerdict
      answer = @app.modal(
        "Plan ready",
        [[Span.new("Approve to start implementing, or send feedback.", Style.new(dim: true))]],
        [{'y', "approve"}, {'n', "give feedback"}, {'q', "stop"}],
        ['y', 'n', 'q']
      )

      case answer
      when 'y'
        Smith::PlanVerdict.approved
      when 'n'
        feedback = @app.modal_text(
          "Feedback",
          [[Span.new("What should the plan change?", Style.new(dim: true))]]
        )
        Smith::PlanVerdict.rejected(feedback.strip)
      else
        Smith::PlanVerdict.halted
      end
    end
  end

  # The hooks trust prompt, asked before the app's own loop runs.
  class TuiTrustPrompt < Smith::TrustPrompt
    def initialize(@tui_app : App, store : TrustStore, preapproved : Bool = false)
      # The IO-based parent is never used for IO; it is the base contract.
      super(store, input: IO::Memory.new, output: IO::Memory.new, preapproved: preapproved)
    end

    def allow?(project_path : String, digest : String, commands : Array(String)) : Bool
      return true if @store.trusted?(project_path, digest)

      if @preapproved
        @store.trust(project_path, digest)
        return true
      end

      body = Array(StyledLine).new
      body << [Span.new(project_path, Style.new(dim: true))]
      body << [Span.new("Hooks run shell commands with your permissions, outside the approval gate:", Style.new(fg: Palette::WARN))]
      commands.each do |command|
        body << [Span.new("  • #{command}", Style.new(fg: Palette::INFO))]
      end

      answer = @tui_app.modal_sync(
        "This project defines hooks",
        body,
        [{'y', "trust"}, {'n', "refuse"}],
        ['y', 'n']
      )

      return false unless answer == 'y'

      @store.trust(project_path, digest)
      true
    end
  end
end
