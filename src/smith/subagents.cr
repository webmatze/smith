require "json"
require "./llm"
require "./tools"
require "./agent"

module Smith::Subagents
  enum Mode
    Work
    Inspect

    def self.from_string(str : String) : Mode
      case str.downcase
      when "inspect" then Inspect
      else                Work
      end
    end
  end

  struct Report
    getter node_id : String
    getter status : String
    getter summary : String
    getter turns_used : Int32
    getter usage : Smith::LLM::Usage

    def initialize(@node_id : String, @status : String, @summary : String, @turns_used : Int32, @usage : Smith::LLM::Usage)
    end

    def to_output_string : String
      String.build do |str|
        str.puts "=== Subagent [#{@node_id}] Report (#{@status}) ==="
        str.puts @summary
        str.puts "\nStats: #{@turns_used} turns | #{@usage.total_tokens} total tokens"
      end
    end
  end

  class Supervisor
    MAX_CHILDREN_PER_SESSION = 20

    getter count : Int32 = 0
    getter approver : Smith::Tools::Approver

    # Plan mode is a property of the whole run, not just the main thread:
    # without this, `agent(mode: "work")` would be a trivial way around it.
    property plan_mode : Bool = false

    # Children build their own registry, so without this a work-mode subagent
    # would run bash straight past the parent's approval gate.
    def initialize(@approver : Smith::Tools::Approver = Smith::Tools::AutoApprover.new)
    end

    def run_child(
      prompt : String,
      mode : Mode,
      provider : Smith::LLM::Provider,
      model : String,
    ) : Report
      if @count >= MAX_CHILDREN_PER_SESSION
        return Report.new(
          node_id: "error",
          status: "rejected",
          summary: "Exceeded max limit of #{MAX_CHILDREN_PER_SESSION} subagents per session.",
          turns_used: 0,
          usage: Smith::LLM::Usage.new(0, 0, 0)
        )
      end

      @count += 1
      node_id = "subagent-#{@count}"

      # In plan mode nothing may change, delegated or not.
      mode = Mode::Inspect if @plan_mode

      # Construct child tool registry based on mode
      registry = build_child_registry(mode)

      child_system_prompt = case mode
                            when Mode::Inspect
                              "You are an inspection subagent. Your task is read-only research and analysis. Provide clear, accurate summaries."
                            else
                              "You are an autonomous child worker agent. Complete the requested task efficiently and report your results."
                            end

      child_agent = Smith::Agent.new(
        provider: provider,
        registry: registry,
        model: model,
        system_prompt: child_system_prompt
      )

      final_text = ""
      turns = 0

      child_agent.on_event do |event|
        case event
        when Smith::Events::AssistantText
          final_text += event.text
        when Smith::Events::TurnCompleted
          turns = event.turns
        end
      end

      # Execute child agent turn inside fiber channel sync
      done_channel = Channel(Nil).new
      spawn do
        begin
          child_agent.send(prompt)
        ensure
          done_channel.send(nil)
        end
      end

      done_channel.receive

      Report.new(
        node_id: node_id,
        status: "completed",
        summary: final_text.empty? ? "(Subagent completed without text output)" : final_text,
        turns_used: turns,
        usage: child_agent.cumulative_usage
      )
    end

    private def build_child_registry(mode : Mode) : Smith::Tools::Registry
      registry = Smith::Tools::Registry.new(@approver)
      registry.register(Smith::Tools::ReadFile.new)
      registry.register(Smith::Tools::Grep.new)
      registry.register(Smith::Tools::Glob.new)

      if mode.work?
        registry.register(Smith::Tools::Bash.new)
        registry.register(Smith::Tools::WriteFile.new)
        registry.register(Smith::Tools::EditFile.new)
      end

      registry
    end
  end
end
