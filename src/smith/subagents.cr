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

  # How many subagents the whole run may spawn, shared by every level.
  #
  # A per-supervisor counter would reset for each nested supervisor, so three
  # levels of twenty would be eight thousand agents — each with its own API
  # calls, each in its own fiber.
  class SpawnBudget
    getter limit : Int32
    getter remaining : Int32

    def initialize(@limit : Int32 = Supervisor::MAX_CHILDREN_PER_SESSION)
      @remaining = @limit
    end

    # Check and decrement in one go. Children run in fibers, and although
    # Crystal's are cooperative, a separate test-then-decrement would be a
    # yield point away from handing out the same slot twice.
    def claim? : Bool
      return false if @remaining <= 0

      @remaining -= 1
      true
    end

    def exhausted? : Bool
      @remaining <= 0
    end
  end

  class Supervisor
    MAX_CHILDREN_PER_SESSION = 20

    # The main agent is depth 0, so this allows three levels of children.
    MAX_DEPTH = 3

    getter count : Int32 = 0
    getter approver : Smith::Tools::Approver
    getter depth : Int32
    getter max_depth : Int32
    getter budget : SpawnBudget

    # Plan mode is a property of the whole run, not just the main thread:
    # without this, `agent(mode: "work")` would be a trivial way around it.
    property plan_mode : Bool = false

    # Children build their own registry, so without the approver a work-mode
    # subagent would run bash straight past the parent's approval gate.
    #
    # `node_path` is this supervisor's own position ("2.1"), which its children
    # extend — an id is then unambiguous across levels.
    def initialize(
      @approver : Smith::Tools::Approver = Smith::Tools::AutoApprover.new,
      @max_depth : Int32 = MAX_DEPTH,
      budget : SpawnBudget? = nil,
      @depth : Int32 = 0,
      @node_path : String = "",
    )
      @budget = budget || SpawnBudget.new
    end

    # The supervisor a child agent would need in order to delegate further.
    # Nothing registers the agent tool for children today, so this is currently
    # only reached from the specs — but the limits are wired here, so whoever
    # does register it (see #21) inherits them instead of reinventing them.
    def child_supervisor(node_path : String) : Supervisor
      supervisor = Supervisor.new(
        approver: @approver,
        max_depth: @max_depth,
        budget: @budget,
        depth: @depth + 1,
        node_path: node_path
      )
      supervisor.plan_mode = @plan_mode
      supervisor
    end

    def run_child(
      prompt : String,
      mode : Mode,
      provider : Smith::LLM::Provider,
      model : String,
    ) : Report
      # Depth before budget: a run that has gone too deep should be told so,
      # not told it is out of spawns.
      if @depth >= @max_depth
        return rejected("Subagent nesting limit reached (depth #{@depth}). Complete this task directly instead of delegating further.")
      end

      unless @budget.claim?
        return rejected("Exceeded max limit of #{@budget.limit} subagents per session.")
      end

      @count += 1
      node_id = "subagent-#{@node_path.empty? ? @count : "#{@node_path}.#{@count}"}"

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

    # Handed back to the model as an ordinary report, the same way the width
    # cap always has been, so it can see the blockage and pick another route.
    private def rejected(summary : String) : Report
      Report.new(
        node_id: "rejected",
        status: "rejected",
        summary: summary,
        turns_used: 0,
        usage: Smith::LLM::Usage.new(0, 0, 0)
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
