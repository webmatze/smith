require "./mode"
require "./tools"

module Smith
  enum PlanDecision
    Approved
    Rejected
    Halted
  end

  struct PlanVerdict
    getter decision : PlanDecision
    getter feedback : String

    def initialize(@decision : PlanDecision, @feedback : String = "")
    end

    def self.approved : PlanVerdict
      new(PlanDecision::Approved)
    end

    def self.rejected(feedback : String) : PlanVerdict
      new(PlanDecision::Rejected, feedback)
    end

    def self.halted : PlanVerdict
      new(PlanDecision::Halted)
    end
  end

  # Decides what happens once the agent presents a plan. An interface for the
  # same reason Tools::Approver is one: the core stays free of UI concerns and
  # the specs can drive it without a terminal.
  abstract class PlanGate
    abstract def review(plan : String) : PlanVerdict
  end

  # --yes: the caller has already said they trust the run.
  class AutoPlanGate < PlanGate
    def review(plan : String) : PlanVerdict
      PlanVerdict.approved
    end
  end

  # Nobody to ask. Stopping is the only safe answer — a headless run must never
  # slide from planning into execution on its own.
  class HaltingPlanGate < PlanGate
    def review(plan : String) : PlanVerdict
      PlanVerdict.halted
    end
  end

  class PromptPlanGate < PlanGate
    def initialize(@input : IO = STDIN, @output : IO = STDOUT)
    end

    def review(plan : String) : PlanVerdict
      loop do
        @output.print "\n   Proceed? [y]es / [n]o (with feedback) / [q]uit: "
        @output.flush

        answer = @input.gets
        # EOF — same rule as the approval gate: do not assume yes.
        return PlanVerdict.halted if answer.nil?

        case answer.strip.downcase
        when "y", "yes"
          return PlanVerdict.approved
        when "n", "no"
          @output.print "   Feedback: "
          @output.flush
          return PlanVerdict.rejected(@input.gets.try(&.strip) || "")
        when "q", "quit"
          return PlanVerdict.halted
        else
          @output.puts "   Please answer y, n or q."
        end
      end
    end
  end

  # The state of a plan-mode run. Deliberately separate from the tool that ends
  # it, so the CLI, the renderers and the subagent supervisor can consult it
  # without knowing about the tool registry — the same split TodoList uses.
  #
  # Everything that has to happen on a mode switch (swapping the registry's
  # approver, rebuilding the system prompt, clamping subagents) is wired by the
  # CLI through `on_mode_change`, which keeps that policy out of the core.
  class PlanSession
    getter mode : Mode
    property gate : PlanGate
    property on_plan : Proc(String, Nil)?
    property on_mode_change : Proc(Mode, Nil)?
    property on_halt : Proc(Nil)?

    def initialize(@mode : Mode = Mode::Normal, @gate : PlanGate = HaltingPlanGate.new)
    end

    def plan_mode? : Bool
      @mode.plan?
    end

    def mode=(mode : Mode) : Nil
      return if @mode == mode

      @mode = mode
      @on_mode_change.try &.call(mode)
    end

    # Called by exit_plan_mode; the return value is what the model sees.
    def present(plan : String) : String
      @on_plan.try &.call(plan)

      verdict = @gate.review(plan)

      case verdict.decision
      in PlanDecision::Approved
        self.mode = Mode::Normal
        "Plan approved. Proceed with implementation."
      in PlanDecision::Rejected
        # Staying in plan mode is the point: the agent revises rather than
        # giving up, and still cannot touch anything meanwhile.
        "Plan rejected. User feedback: #{verdict.feedback}"
      in PlanDecision::Halted
        @on_halt.try &.call
        "Plan presented. Stopping without making changes."
      end
    end
  end
end
