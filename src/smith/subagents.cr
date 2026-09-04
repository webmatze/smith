require "json"
require "./llm"
require "./tools"
require "./agent"
require "./agents"
require "./media"

module Smith::Subagents
  enum Mode
    Work
    Inspect

    # nil rather than a default, deliberately. A mode is a security statement,
    # and the method that silently turned every unreadable value into `Work`
    # handed the full tool set to anyone who mistyped `inspect`. Each caller
    # now says for itself what an unknown value costs — see `Agents::Catalog#parse`
    # and `Tools::AgentTool#run`.
    def self.from_string?(str : String) : Mode?
      case str.downcase
      when "work"    then Work
      when "inspect" then Inspect
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
    # A definition may name a different provider, but building one needs API
    # keys and config that belong in the CLI — so the CLI injects a factory
    # rather than having that logic duplicated here.
    property provider_factory : Proc(String, Smith::LLM::Provider)?

    # What a child's `read_file` may attach, `[media] max_bytes`. Injected for
    # the same reason as the factory: the setting lives in config, which is
    # the CLI's business, not this supervisor's.
    property max_media_bytes : Int32 = Smith::Media::DEFAULT_MAX_BYTES

    def initialize(
      @approver : Smith::Tools::Approver = Smith::Tools::AutoApprover.new,
      @max_depth : Int32 = MAX_DEPTH,
      budget : SpawnBudget? = nil,
      @depth : Int32 = 0,
      @node_path : String = "",
      @warn_io : IO = STDERR,
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
        node_path: node_path,
        warn_io: @warn_io
      )
      supervisor.plan_mode = @plan_mode
      supervisor.provider_factory = @provider_factory
      supervisor.max_media_bytes = @max_media_bytes
      supervisor
    end

    # Whether a child of this supervisor could itself delegate. Used to decide
    # whether offering the agent tool is worth the tokens.
    def children_may_nest? : Bool
      @depth + 1 < @max_depth
    end

    def run_child(
      prompt : String,
      mode : Mode,
      provider : Smith::LLM::Provider,
      model : String,
      definition : Smith::Agents::Definition? = nil,
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
      path = @node_path.empty? ? @count.to_s : "#{@node_path}.#{@count}"
      node_id = "subagent-#{path}"

      mode = definition.mode if definition
      # In plan mode nothing may change, delegated or not — a definition's own
      # tool list must not be a way around that.
      mode = Mode::Inspect if @plan_mode

      child_model = definition.try(&.model) || model
      child_provider = resolve_provider(definition, provider)
      registry = build_child_registry(tool_names(definition, mode), path, child_provider, child_model)

      child_system_prompt = definition.try(&.system_prompt.presence) || case mode
      when Mode::Inspect
        "You are an inspection subagent. Your task is read-only research and analysis. Provide clear, accurate summaries."
      else
        "You are an autonomous child worker agent. Complete the requested task efficiently and report your results."
      end

      child_agent = Smith::Agent.new(
        provider: child_provider,
        registry: registry,
        model: child_model,
        system_prompt: child_system_prompt
      )

      final_text = ""
      turns = 0
      failure = nil.as(String?)

      child_agent.on_event do |event|
        case event
        when Smith::Events::AssistantText
          final_text += event.text
        when Smith::Events::TurnCompleted
          turns = event.turns
        when Smith::Events::ContextExhausted
          # A child that ran out of window returns from run_loop with no text,
          # which is indistinguishable from a quiet success unless it is caught
          # here — no renderer is attached to a child to notice it.
          failure = "Subagent ran out of context (~#{event.estimated_tokens} tokens " \
                    "against a #{event.budget_tokens} budget) before it could work. " \
                    "Delegate a narrower task."
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

      if reason = failure
        return Report.new(
          node_id: node_id,
          status: "failed",
          summary: reason,
          turns_used: turns,
          usage: child_agent.cumulative_usage
        )
      end

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

    private def resolve_provider(definition : Smith::Agents::Definition?, fallback : Smith::LLM::Provider) : Smith::LLM::Provider
      name = definition.try(&.provider)
      return fallback if name.nil?

      factory = @provider_factory
      return fallback if factory.nil?

      factory.call(name)
    end

    # Plan mode wins over a definition's list, for the same reason it forces
    # Inspect: otherwise `tools: bash` in a markdown file would undo it.
    private def tool_names(definition : Smith::Agents::Definition?, mode : Mode) : Array(String)
      names = definition.try(&.tool_names) || (mode.inspect? ? Smith::Agents::Definition::INSPECT_TOOLS : Smith::Agents::Definition::WORK_TOOLS)
      return names unless mode.inspect?

      names & Smith::Agents::Definition::INSPECT_TOOLS
    end

    private def build_child_registry(
      names : Array(String),
      node_path : String,
      provider : Smith::LLM::Provider,
      model : String,
    ) : Smith::Tools::Registry
      registry = Smith::Tools::Registry.new(@approver)

      names.each do |name|
        # Withheld rather than unknown: at the deepest level every call to it
        # would be refused, so it is simply not offered.
        next if name == "agent" && !children_may_nest?

        tool = build_tool(name, node_path, provider, model)
        if tool.nil?
          @warn_io.puts "⚠️  Unknown tool '#{name}' in agent definition — ignored."
          next
        end

        registry.register(tool)
      end

      registry
    end

    private def build_tool(
      name : String,
      node_path : String,
      provider : Smith::LLM::Provider,
      model : String,
    ) : Smith::Tools::Tool?
      case name
      when "read_file"  then Smith::Tools::ReadFile.new(max_media_bytes: @max_media_bytes)
      when "grep"       then Smith::Tools::Grep.new
      when "glob"       then Smith::Tools::Glob.new
      when "bash"       then Smith::Tools::Bash.new
      when "write_file" then Smith::Tools::WriteFile.new
      when "edit_file"  then Smith::Tools::EditFile.new
      when "agent"
        # A definition may ask to delegate further. The child supervisor
        # carries the depth and the shared budget, so this stays bounded —
        # the invariant #20 put in place.
        Smith::Tools::AgentTool.new(
          supervisor: child_supervisor(node_path),
          provider: provider,
          model: model
        )
      end
    end
  end
end
