require "./output"
require "./tools"
require "./plan"
require "./trust"

module Smith
  # How a run talks to the human, and how it asks them things.
  #
  # There are two of these — plain lines and the fullscreen UI — and almost
  # everything that differs between them is a constructor: which renderer the
  # event stream goes to, which approver asks about a tool call, which gate
  # reviews a plan, where a hook's warning lands. Gathering them here is what
  # keeps the CLI from growing another `if fullscreen?` every time the UI
  # learns to do something new.
  #
  # What it deliberately does *not* decide is *whether* to ask: `--yes`, a
  # missing TTY and plan mode all settle that before anyone gets here. This
  # only knows how the asking looks.
  abstract class Presentation
    abstract def renderer : Output::Renderer

    # Where diagnostics that are nobody's event go — a hook warning, an MCP
    # server that would not start.
    abstract def notice_io : IO

    abstract def approver(allowlist : Array(String), rules : Tools::RuleSet) : Tools::Approver
    abstract def trust_prompt(store : TrustStore, preapproved : Bool) : TrustPrompt
    abstract def plan_gate : PlanGate

    # One line of incidental text: a chat command's answer, a note about
    # shutting jobs down. Not an event, and not part of the transcript.
    abstract def say(text : String) : Nil

    # Lines that are already laid out — a table, a breakdown — and must be
    # shown as they are.
    abstract def say_block(lines : Array(String)) : Nil

    # `/clear` — the fullscreen UI wipes the screen, plain output has no
    # screen to wipe and is a no-op.
    abstract def clear_screen : Nil
  end

  # The line-based presentation, wrapped around whichever renderer the run
  # asked for: human text, or JSONL. Both prompt on the terminal, and both
  # keep that prompt off stdout — in JSON mode a question printed there would
  # corrupt the stream mid-line, which is what `prompt_io` exists to avoid.
  class PlainPresentation < Presentation
    getter renderer : Output::Renderer

    def initialize(@renderer : Output::Renderer)
    end

    def notice_io : IO
      STDERR
    end

    def approver(allowlist : Array(String), rules : Tools::RuleSet) : Tools::Approver
      Tools::PromptApprover.new(
        allowlist: allowlist,
        output: @renderer.prompt_io,
        rules: rules
      )
    end

    def trust_prompt(store : TrustStore, preapproved : Bool) : TrustPrompt
      TrustPrompt.new(
        store,
        input: STDIN,
        output: @renderer.prompt_io,
        preapproved: preapproved
      )
    end

    def plan_gate : PlanGate
      PromptPlanGate.new(STDIN, @renderer.prompt_io)
    end

    # Both go to `prompt_io` for the reason a question does: in JSON mode a
    # line on stdout lands in the middle of the JSONL stream and breaks the
    # record it interrupts. In human mode `prompt_io` *is* stdout, so this is
    # the ordinary place either way.
    #
    # `say` indents, because plain output has no block structure to set a
    # stray line apart from the transcript around it.
    def say(text : String) : Nil
      @renderer.prompt_io.puts "   #{text}"
    end

    def say_block(lines : Array(String)) : Nil
      lines.each { |line| @renderer.prompt_io.puts line }
    end

    # Plain output has no screen; the context itself is cleared by the caller.
    def clear_screen : Nil
    end
  end
end
