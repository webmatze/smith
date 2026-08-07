require "json"
require "./tool"
require "../subagents"
require "../agents"
require "../llm/provider"

module Smith::Tools
  class AgentTool < Tool
    getter supervisor : Smith::Subagents::Supervisor
    getter provider : Smith::LLM::Provider
    getter model : String
    getter agents : Smith::Agents::Catalog

    def initialize(
      @supervisor : Smith::Subagents::Supervisor,
      @provider : Smith::LLM::Provider,
      @model : String,
      @agents : Smith::Agents::Catalog = Smith::Agents::Catalog.new,
    )
    end

    def name : String
      "agent"
    end

    def description : String
      base = "Delegate a subtask to an autonomous child subagent. Mode can be 'work' (full capabilities) or 'inspect' (read-only research)."
      # Only mentioned when there is something to choose from, so a project
      # without agent definitions pays nothing for the feature.
      "#{base}#{@agents.summary_prompt}"
    end

    def parameters : JSON::Any
      JSON.parse(JSON.build do |json|
        json.object do
          json.field "type", "object"
          json.field "properties" do
            json.object do
              json.field "prompt" do
                json.object do
                  json.field "type", "string"
                  json.field "description", "Clear subtask instructions for the child agent."
                end
              end

              json.field "mode" do
                json.object do
                  json.field "type", "string"
                  json.field "enum", %w[work inspect]
                  json.field "description", "Execution mode: 'work' for edits/shell commands, 'inspect' for read-only research."
                end
              end

              unless @agents.agents.empty?
                json.field "agent_type" do
                  json.object do
                    json.field "type", "string"
                    json.field "enum", @agents.agents.keys
                    json.field "description", "A specialised agent to run instead of the generic one. Overrides 'mode'."
                  end
                end
              end
            end
          end
          json.field "required", %w[prompt]
        end
      end)
    end

    def run(args : JSON::Any) : String
      prompt = args["prompt"]?.try(&.as_s?)
      return "Error: 'prompt' argument is required." if prompt.nil?

      definition = nil
      if requested = args["agent_type"]?.try(&.as_s?)
        definition = @agents[requested]
        if definition.nil?
          known = @agents.agents.keys
          return "Error: unknown agent_type '#{requested}'. " +
            (known.empty? ? "No agents are defined." : "Available: #{known.join(", ")}.")
        end
      end

      mode_str = args["mode"]?.try(&.as_s?) || "work"
      mode = Smith::Subagents::Mode.from_string(mode_str)

      report = @supervisor.run_child(
        prompt: prompt,
        mode: mode,
        provider: @provider,
        model: @model,
        definition: definition
      )

      report.to_output_string
    end
  end
end
