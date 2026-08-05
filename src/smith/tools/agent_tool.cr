require "json"
require "./tool"
require "../subagents"
require "../llm/provider"

module Smith::Tools
  class AgentTool < Tool
    getter supervisor : Smith::Subagents::Supervisor
    getter provider : Smith::LLM::Provider
    getter model : String

    def initialize(
      @supervisor : Smith::Subagents::Supervisor,
      @provider : Smith::LLM::Provider,
      @model : String
    )
    end

    def name : String
      "agent"
    end

    def description : String
      "Delegate a subtask to an autonomous child subagent. Mode can be 'work' (full capabilities) or 'inspect' (read-only research)."
    end

    def parameters : JSON::Any
      JSON.parse(%({
        "type": "object",
        "properties": {
          "prompt": {
            "type": "string",
            "description": "Clear subtask instructions for the child agent."
          },
          "mode": {
            "type": "string",
            "enum": ["work", "inspect"],
            "description": "Execution mode: 'work' for edits/shell commands, 'inspect' for read-only research."
          }
        },
        "required": ["prompt"]
      }))
    end

    def run(args : JSON::Any) : String
      prompt = args["prompt"]?.try(&.as_s?)
      return "Error: 'prompt' argument is required." if prompt.nil?

      mode_str = args["mode"]?.try(&.as_s?) || "work"
      mode = Smith::Subagents::Mode.from_string(mode_str)

      report = @supervisor.run_child(
        prompt: prompt,
        mode: mode,
        provider: @provider,
        model: @model
      )

      report.to_output_string
    end
  end
end
