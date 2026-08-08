require "../presentation"
require "./app"
require "./renderer"
require "./gates"

module Smith::UI
  # The fullscreen presentation: everything goes through the app, which owns
  # the screen. Questions become panels answered with a single key, so no part
  # of a session reads from plain stdin while the UI has the terminal in raw
  # mode — a prompt printed underneath it would be invisible, and a `gets`
  # would fight the key loop for the same bytes.
  class TuiPresentation < Smith::Presentation
    getter app : App

    def initialize(@app : App)
      @renderer = TuiRenderer.new(@app)
    end

    def renderer : Smith::Output::Renderer
      @renderer
    end

    def notice_io : IO
      @notice_io ||= NoticeIO.new(@app)
    end

    def approver(allowlist : Array(String), rules : Smith::Tools::RuleSet) : Smith::Tools::Approver
      TuiApprover.new(@app, allowlist: allowlist, rules: rules)
    end

    def trust_prompt(store : Smith::TrustStore, preapproved : Bool) : Smith::TrustPrompt
      TuiTrustPrompt.new(@app, store, preapproved: preapproved)
    end

    def plan_gate : Smith::PlanGate
      TuiPlanGate.new(@app)
    end

    # A notice block is already set apart from what surrounds it, so the text
    # arrives as it was written.
    def say(text : String) : Nil
      @app.notice(text)
    end

    def say_block(lines : Array(String)) : Nil
      @app.notice(lines.map { |text| [Span.new(text, Style.new(fg: Palette::INFO))] of Span })
    end
  end
end
