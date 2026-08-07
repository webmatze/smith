require "json"
require "./tool"
require "../plan"

module Smith::Tools
  # Ends the research phase by presenting a plan for approval. Registered only
  # while plan mode is active.
  #
  # Not mutating on purpose: the approval gate in plan mode is the PlanApprover,
  # which refuses everything — marking this tool mutating would block the only
  # way out of plan mode.
  class ExitPlanMode < Tool
    def initialize(@plan : Smith::PlanSession)
    end

    def name : String
      "exit_plan_mode"
    end

    def description : String
      <<-DESC
      Call this once your research is done and you have a concrete plan. It shows the plan to the user and asks whether to proceed.

      Only call it when the task actually requires changes. Pure questions are answered directly instead.

      The user may reject the plan with feedback; revise and call again. Until the plan is approved, every mutating tool stays unavailable.
      DESC
    end

    def parameters : JSON::Any
      JSON.parse(%({
        "type": "object",
        "properties": {
          "plan": {
            "type": "string",
            "description": "The plan in markdown: the concrete steps you intend to take, concise but specific about files and changes."
          }
        },
        "required": ["plan"]
      }))
    end

    def run(args : JSON::Any) : String
      plan = args["plan"]?.try(&.as_s?)
      return "Error: 'plan' argument is required (the plan in markdown)." if plan.nil?

      @plan.present(plan)
    end
  end
end
