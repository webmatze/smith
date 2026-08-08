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
  end

  # The line-based presentation, wrapped around whichever renderer the run
  # asked for: human text, or JSONL. Both prompt on the terminal, and both
  # keep that prompt off stdout — in JSON mode a question printed there would
  # corrupt the stream mid-line, which is what `prompt_io` exists to avoid.
  class PlainPresentation < Presentation
    getter renderer : Output::Renderer

    def initialize(@renderer : Output::Renderer, @io : IO = STDOUT)
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

    # Indented, because plain output has no block structure to set a stray
    # line apart from the transcript around it.
    def say(text : String) : Nil
      @io.puts "   #{text}"
    end

    def say_block(lines : Array(String)) : Nil
      lines.each { |line| @io.puts line }
    end
  end
end
