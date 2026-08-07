require "option_parser"
require "./llm"
require "./tools"
require "./agent"
require "./session"
require "./project_ctx"
require "./skills"
require "./agents"
require "./config"
require "./output"
require "./todos"
require "./plan"
require "./chat_commands"
require "./checkpoints"
require "./hooks"
require "./trust"

module Smith
  class CLI
    def self.start(args : Array(String))
      new(args).run
    end

    @args : Array(String)
    @model : String? = nil
    @provider_name : String? = nil
    @auto_approve : Bool = false
    @json_output : Bool = false
    @stream : Bool? = nil
    @renderer : Output::Renderer? = nil
    @session_store : Session::Store
    @skills_catalog : Skills::Catalog
    @agents_catalog : Agents::Catalog
    @agent_name : String? = nil
    @config : Config
    @todos = TodoList.new
    @trust_hooks : Bool = false
    @hooks : Hooks::Runner? = nil
    @session_id : String = "headless"
    @hook_context : String? = nil
    @checkpoints : Checkpoints::Store? = nil
    @rewind_to : String? = nil
    @files_only : Bool = false
    @dry_run : Bool = false
    @force : Bool = false
    @mode : Mode? = nil
    @plan : PlanSession? = nil
    @real_approver : Tools::Approver? = nil

    def initialize(@args : Array(String))
      @config = Config.load
      @session_store = Session::Store.new
      @skills_catalog = Skills::Catalog.discover
      @agents_catalog = Agents::Catalog.discover
    end

    # The definition driving the *main* thread, when --agent was passed.
    private def main_agent : Agents::Definition?
      name = @agent_name
      return nil if name.nil?

      definition = @agents_catalog[name]
      if definition.nil?
        known = @agents_catalog.agents.keys
        STDERR.puts "❌ Error: unknown agent '#{name}'."
        STDERR.puts(known.empty? ? "   No agents are defined in .smith/agents/ or ~/.smith/agents/." : "   Known agents: #{known.join(", ")}")
        exit(1)
      end

      definition
    end

    # The provider actually in effect: CLI flag (or a resumed session's
    # provider) first, otherwise whatever the config/env/default chain yields.
    private def effective_provider_name : String
      @provider_name || main_agent.try(&.provider) || @config.provider
    end

    # Same precedence as everywhere else: flag first, then env/config/default.
    private def effective_mode : Mode
      @mode || @config.mode
    end

    def run
      parser = OptionParser.new do |opts|
        opts.banner = String.build do |str|
          str.puts "⚒️  Smith LLM Agent Harness v#{Smith::VERSION} (Crystal)\n"
          str.puts "Usage: smith [command] [options] [prompt]\n"
          str.puts "Commands:"
          str.puts "  chat                       Start an interactive chat session (default)"
          str.puts "  run <prompt>               Run a single prompt in headless mode and exit"
          str.puts "  resume [<session_id>]      Resume an existing session (or latest session)"
          str.puts "  sessions, list             List all saved local chat sessions"
          str.puts "  checkpoints [<session_id>] List the file snapshots taken during a session"
          str.puts "  rewind [<session_id>]      Undo a session's file changes\n"
          str.puts "Options:"
        end

        opts.on("-m MODEL", "--model=MODEL", "Specify the LLM model (defaults to provider's default model)") do |m|
          @model = m
        end

        opts.on("-p PROVIDER", "--provider=PROVIDER", "Specify the provider: openrouter, ollama, anthropic, openai (default: from config, else openrouter)") do |p|
          @provider_name = p
        end

        opts.on("-y", "--yes", "Auto-approve mutating tools (bash, write_file, edit_file)") do
          @auto_approve = true
        end

        opts.on("--auto-approve", "Alias for --yes") do
          @auto_approve = true
        end

        opts.on("--to CHECKPOINT", "rewind: undo this checkpoint and everything after it (default: only the newest)") do |value|
          @rewind_to = value
        end

        opts.on("--files-only", "rewind: restore files but leave the transcript alone") do
          @files_only = true
        end

        opts.on("--dry-run", "rewind: show what would change, change nothing") do
          @dry_run = true
        end

        opts.on("--force", "rewind: overwrite files changed outside smith since the snapshot") do
          @force = true
        end

        opts.on("--agent NAME", "Run the main thread as the agent defined in .smith/agents/NAME.md") do |name|
          @agent_name = name
        end

        opts.on("--trust-hooks", "Trust this project's hooks without asking (they run arbitrary commands)") do
          @trust_hooks = true
        end

        opts.on("--plan", "Start in plan mode: research only, until you approve a plan") do
          @mode = Mode::Plan
        end

        opts.on("--json", "Emit JSON Lines on stdout (headless 'run' only)") do
          @json_output = true
        end

        opts.on("--no-stream", "Wait for the complete response instead of streaming it") do
          @stream = false
        end

        opts.on("-v", "--version", "Print version information") do
          puts "smith version #{Smith::VERSION}"
          exit
        end

        opts.on("-h", "--help", "Show this help banner") do
          puts opts
          puts "\nFeatures & Usage Notes:"
          puts "  • Skills: Place skills in ~/.smith/skills/<name>/SKILL.md or .smith/skills/<name>/SKILL.md"
          puts "    Reference via $skill-name or /skill-name in prompt."
          puts "  • Project Context: Instructions in SMITH.md or AGENTS.md are automatically loaded into prompt."
          puts "  • Subagents: Agent can delegate tasks using the 'agent' tool (mode: 'work' or 'inspect')."
          puts "  • Custom Agents: Define specialists in .smith/agents/<name>.md or ~/.smith/agents/<name>.md"
          puts "    Delegate via agent_type, or run one directly with --agent <name>."
          puts "  • Persistence: Sessions are saved under ~/.smith/sessions/ and can be resumed with 'smith resume'."
          puts "  • Plan Mode: --plan (or [defaults] mode = \"plan\") researches first and asks before changing anything."
          puts "    In chat, /plan and /normal switch at runtime; these built-ins win over a skill of the same name."
          exit
        end
      end

      parser.parse(@args)

      command = @args.first? || "chat"

      # JSON Lines only make sense for a single headless run; anything else
      # would silently do something other than what was asked.
      if @json_output && !headless?(command)
        STDERR.puts "❌ Error: --json is only supported for headless runs ('smith run')."
        exit(1)
      end

      case command
      when "run"
        prompt = @args[1..-1]?.try(&.join(" ")) || ""
        if prompt.empty?
          STDERR.puts "Error: 'smith run' requires a prompt argument."
          STDERR.puts "Example: smith run \"Refactor src/smith.cr\""
          exit(1)
        end
        run_headless(prompt)
      when "chat", "interactive"
        run_interactive
      when "resume"
        session_id = @args[1]?
        run_resume(session_id)
      when "sessions", "list"
        list_sessions
      when "checkpoints"
        list_checkpoints(@args[1]?)
      when "rewind"
        run_rewind(@args[1]?)
      else
        prompt = @args.join(" ")
        if prompt.empty?
          run_interactive
        else
          run_headless(prompt)
        end
      end
    end

    KNOWN_COMMANDS = %w[run chat interactive resume sessions list checkpoints rewind]

    # `run <prompt>`, or a bare prompt with no subcommand — both end up in
    # run_headless.
    private def headless?(command : String) : Bool
      return true if command == "run"
      !KNOWN_COMMANDS.includes?(command) && !@args.join(" ").strip.empty?
    end

    private def renderer : Output::Renderer
      @renderer ||= if @json_output
                      Output::JsonRenderer.new
                    else
                      Output::HumanRenderer.new
                    end
    end

    private def build_provider(provider_name : String = effective_provider_name) : LLM::Provider
      name = provider_name.downcase
      # -m wins over the config/env chain; nil means "ask the config".
      default_m = @model || @config.model_for(name)

      http = @config.http
      timeouts = LLM::Timeouts.from_seconds(http.connect_timeout, http.read_timeout)

      case name
      when "openrouter"
        LLM::OpenRouter.new(api_key: require_api_key("OPENROUTER_API_KEY"), default_model: default_m, timeouts: timeouts)
      when "ollama"
        LLM::Ollama.new(host: @config.ollama_host, default_model: default_m, timeouts: timeouts)
      when "anthropic"
        LLM::Anthropic.new(api_key: require_api_key("ANTHROPIC_API_KEY"), default_model: default_m, timeouts: timeouts, cache: @config.cache_for(name))
      when "openai"
        LLM::OpenAI.new(api_key: require_api_key("OPENAI_API_KEY"), default_model: default_m, timeouts: timeouts)
      else
        STDERR.puts "❌ Error: Unknown provider '#{provider_name}'."
        STDERR.puts "   Known providers: #{Config::BUILTIN_MODELS.keys.join(", ")}"
        exit(1)
      end
    end

    # API keys stay env-only and are never read from the config file, so a
    # plaintext config never becomes a place secrets get committed from.
    private def require_api_key(var_name : String) : String
      api_key = ENV[var_name]?
      if api_key.nil? || api_key.empty?
        STDERR.puts "❌ Error: #{var_name} environment variable is not set."
        STDERR.puts "   Please set it via: export #{var_name}=\"your_key_here\""
        exit(1)
      end
      api_key
    end

    private def build_system_prompt : String
      # A definition replaces the built-in preamble outright — the point of
      # --agent is a single-purpose runner, not smith wearing a hat.
      if definition = main_agent
        blocks = [definition.system_prompt]
        blocks << @hook_context.not_nil! if @hook_context
        return blocks.join("\n\n")
      end

      base_prompt = String.build do |str|
        str.puts "You are Smith, an autonomous coding agent written in Crystal."
        str.puts "\nSkill Storage Policy:"
        str.puts "  • Project-local: .smith/skills/<name>/SKILL.md (recommended for project-specific skills)"
        str.puts "  • Global: ~/.smith/skills/<name>/SKILL.md (available across all user projects)"
        str.puts "When creating a new skill, if the user has not specified the location, ask the user first where they want to store the new skill."
      end

      blocks = [base_prompt]

      if plan_session.plan_mode?
        blocks << <<-PLAN
        Plan Mode — you are researching, not building:
          • Every mutating tool (bash, write_file, edit_file) is unavailable, and subagents are forced into read-only inspect mode. Do not try to work around that.
          • Understand the code first with read_file, grep and glob.
          • Then call exit_plan_mode with a concrete, step-by-step plan that names the files you intend to change. Writing the plan as prose and stopping does not work — the user only sees it through exit_plan_mode.
          • If the request needs no changes at all, simply answer it.
        PLAN
      end

      if skill_summary = @skills_catalog.summary_prompt
        blocks << skill_summary
      end

      if project_instructions = ProjectContext.discover
        blocks << project_instructions
      end

      if hook_context = @hook_context
        blocks << hook_context
      end

      blocks.join("\n\n")
    end

    # CLI-Flag > [approval] mode. Without a TTY there is nobody to ask, so
    # prompt mode degrades to refusing rather than silently running.
    private def build_approver : Tools::Approver
      approval = @config.approval
      rules = Tools::RuleSet.build(
        allow: approval.allow,
        ask: approval.ask,
        deny: approval.deny,
        project_dir: Dir.current
      )

      inner = if @auto_approve || approval.mode.downcase == "auto"
                Tools::AutoApprover.new
              elsif !STDIN.tty?
                Tools::DenyApprover.new
              else
                # In JSON mode the prompt must not land on stdout, or it would
                # corrupt the JSONL stream mid-line.
                Tools::PromptApprover.new(
                  allowlist: approval.allowlist,
                  output: renderer.prompt_io,
                  rules: rules
                )
              end

      # Wrapped even when there are no rules, so the composition is the same
      # everywhere; an empty RuleSet decides Unset and costs a hash lookup.
      # Wrapping is also what makes deny survive --yes: the flag only replaces
      # the inner approver.
      Tools::RuleApprover.new(rules, inner)
    end

    # A project config that defines hooks is code from whoever wrote the repo,
    # so it needs a one-time trust decision. `--yes` deliberately does not
    # grant it — that flag is about tools the *model* chose, not about code a
    # checkout brought with it. `--trust-hooks` is the explicit opt-in.
    private def hooks : Hooks::Runner
      @hooks ||= begin
        definitions = if (digest = @config.project_hooks_digest) && !project_hooks_allowed?(digest)
                        STDERR.puts "⚠️  This project's hooks are not trusted — running global hooks only."
                        @config.global_hooks
                      else
                        @config.hooks
                      end

        runner = Hooks::Runner.new(definitions, session_id: @session_id)
        runner.on_fire = ->(event : Hooks::Event, command : String, blocked : Bool) do
          renderer.handle(Events::HookFired.new(event, command, blocked))
        end
        runner
      end
    end

    private def project_hooks_allowed?(digest : String) : Bool
      project = Config.project_path
      return false if project.nil?

      TrustPrompt.new(
        TrustStore.new,
        input: STDIN,
        output: renderer.prompt_io,
        preapproved: @trust_hooks
      ).allow?(project, digest, @config.hooks.map(&.command))
    end

    private def plan_session : PlanSession
      @plan ||= PlanSession.new(effective_mode, build_plan_gate)
    end

    # Mirrors build_approver: --yes trusts the run outright, and without a TTY
    # there is nobody to ask — in which case presenting the plan is as far as
    # the run goes. Headless must never slide into execution on its own.
    private def build_plan_gate : PlanGate
      return AutoPlanGate.new if @auto_approve
      return HaltingPlanGate.new unless STDIN.tty?

      PromptPlanGate.new(STDIN, renderer.prompt_io)
    end

    # The whole feature is this method plus a swapped approver: Registry#approver
    # is a property, so a mode switch needs no structural change.
    private def apply_mode(registry : Tools::Registry, supervisor : Subagents::Supervisor, mode : Mode) : Nil
      case mode
      in Mode::Plan
        registry.approver = Tools::PlanApprover.new
        registry.register(Tools::ExitPlanMode.new(plan_session))
        supervisor.plan_mode = true
      in Mode::Normal
        registry.approver = @real_approver || build_approver
        registry.unregister("exit_plan_mode")
        supervisor.plan_mode = false
      end
    end

    private def build_agent(provider : LLM::Provider, messages : Array(LLM::Message)? = nil) : Agent
      effective_model = @model || main_agent.try(&.model) || provider.default_model

      # Built once and kept, so the [a]lways answers survive a plan-mode
      # detour instead of being asked again afterwards.
      approver = (@real_approver ||= build_approver)
      registry = Tools::Registry.default(approver, todos: @todos)
      registry.hooks = hooks
      registry.checkpoints = @checkpoints

      # Fired before the system prompt is built, so a hook can inject context
      # into it — the branch, the open tickets, whatever the project needs.
      @hook_context ||= hooks.run(Hooks::Event::SessionStart).additional_context

      # Tools have no access to the agent's event bus, and giving them one
      # would put event knowledge into the policy-free core. The list's
      # on_change hook is the seam instead.
      @todos.on_change = ->(items : Array(TodoList::Item)) do
        renderer.handle(Events::TodosUpdated.new(items))
      end

      subagents = @config.subagents
      supervisor = Subagents::Supervisor.new(
        approver,
        max_depth: subagents.max_depth,
        budget: Subagents::SpawnBudget.new(subagents.max_children)
      )
      # Building a provider needs API keys and the config chain, which belong
      # here rather than duplicated in the supervisor.
      supervisor.provider_factory = ->(name : String) { build_provider(name) }

      # max_children = 0 means "no subagents at all", so the tool is not even
      # advertised — offering one that always refuses just wastes turns.
      unless subagents.max_children.zero?
        registry.register(Tools::AgentTool.new(
          supervisor: supervisor,
          provider: provider,
          model: effective_model,
          agents: @agents_catalog
        ))
      end

      # --agent narrows the main thread's tools the same way a definition
      # narrows a child's. Done last, after every tool is registered, so the
      # agent tool is subject to it too: a definition has to ask for `agent`
      # to get it, on the main thread as much as in a child.
      if definition = main_agent
        registry.specs.map(&.name).each do |registered|
          registry.unregister(registered) unless definition.tool_names.includes?(registered)
        end
      end

      agent = Agent.new(
        provider: provider,
        registry: registry,
        model: effective_model,
        system_prompt: build_system_prompt,
        messages: messages,
        max_context_tokens: @config.context.max_tokens,
        stream: @stream.nil? ? @config.stream? : @stream.not_nil!,
        hooks: hooks
      )

      agent.on_event do |event|
        renderer.handle(event)
      end

      plan = plan_session
      plan.on_plan = ->(text : String) do
        renderer.handle(Events::PlanPresented.new(text))
      end
      plan.on_halt = -> { agent.stop! }
      plan.on_mode_change = ->(mode : Mode) do
        apply_mode(registry, supervisor, mode)
        # The mode is part of the system prompt, so a runtime switch has to
        # rebuild it — otherwise the model keeps its old marching orders.
        agent.system_prompt = build_system_prompt
        renderer.handle(Events::ModeChanged.new(mode))
      end

      apply_mode(registry, supervisor, plan.mode)

      agent
    end

    # Every prompt passes through here, so a user_prompt_submit hook cannot be
    # bypassed by using a different entry point.
    private def submit(agent : Agent, text : String) : Bool
      payload = JSON.parse(JSON.build do |json|
        json.object { json.field "prompt", text }
      end)

      outcome = hooks.run(Hooks::Event::UserPromptSubmit, payload)
      if outcome.blocked?
        renderer.handle(Events::TurnError.new(outcome.reason || "Prompt blocked by a user_prompt_submit hook."))
        return false
      end

      expanded = @skills_catalog.expand_prompt(text)
      if context = outcome.additional_context
        expanded = "#{expanded}\n\n#{context}"
      end

      agent.send(expanded)
      true
    end

    private def run_headless(prompt : String)
      provider = build_provider
      agent = build_agent(provider)

      renderer.banner(provider.name, agent.model, @skills_catalog.skills.keys)
      # on_mode_change only fires on a *switch*, so the starting mode is
      # announced here — otherwise a --plan run would look like a normal one.
      renderer.handle(Events::ModeChanged.new(Mode::Plan)) if plan_session.plan_mode?

      submit(agent, prompt)
      renderer.finish(agent.cumulative_usage)

      # A failed provider call must not report success to a calling script.
      exit(renderer.exit_code)
    end

    private def run_interactive
      provider = build_provider
      effective_model = @model || provider.default_model

      session_data = @session_store.create(model: effective_model, provider: effective_provider_name)
      start_session_loop(session_data)
    end

    private def run_resume(session_id : String?)
      session_data = if session_id
                       @session_store.load(session_id)
                     else
                       @session_store.latest
                     end

      if session_data.nil?
        puts "❌ No sessions found to resume."
        exit(1)
      end

      @model = session_data.model
      @provider_name = session_data.provider

      puts "🔄 Resuming Session [#{session_data.id}]"
      puts "   Provider: #{@provider_name} | Model: #{@model} | Messages: #{session_data.messages.size}"
      puts "--------------------------------------------------"

      session_data.messages.last(4).each do |msg|
        role_label = msg.role.user? ? "\e[36muser>\e[0m" : "\e[32massistant>\e[0m"
        text = msg.content.select { |b| b.type.text? }.map(&.text).compact.join("\n")
        unless text.empty?
          puts "#{role_label} #{text[0..100]}"
        end
      end
      puts "--------------------------------------------------"

      start_session_loop(session_data)
    end

    private def start_session_loop(session_data : Session::Data)
      # Set before the runner is built, so hooks see the real session id.
      @session_id = session_data.id

      settings = @config.checkpoints
      store = Checkpoints::Store.new(@session_store.session_dir(session_data.id), enabled: settings.enabled?)
      store.prune(max: settings.max_per_session, retention: settings.retention)
      @checkpoints = store
      provider = build_provider(session_data.provider)
      agent = build_agent(provider, session_data.messages)
      effective_model = agent.model

      puts "⚒️  Smith LLM Agent Harness v#{Smith::VERSION} (Crystal)"
      puts "   Session: #{session_data.id} | Provider: #{session_data.provider} | Model: #{effective_model}"
      if @skills_catalog.skills.size > 0
        puts "   Loaded Skills: #{@skills_catalog.skills.keys.join(", ")}"
      end
      if @agents_catalog.agents.size > 0
        puts "   Loaded Agents: #{@agents_catalog.agents.keys.join(", ")}"
      end
      if definition = main_agent
        puts "   Running as agent: #{definition.name}"
      end
      puts "   Mode: plan (research only — /normal to leave)" if plan_session.plan_mode?
      puts "   Type 'exit' or 'quit' to end session.\n\n"

      # Resuming without the plan would leave the model to reconstruct it from
      # a transcript that compaction may already have shortened.
      @todos.replace(session_data.todos) unless session_data.todos.empty?

      install_interrupt_handler(session_data, agent)

      loop do
        print "\n\e[36msmith>\e[0m "
        STDOUT.flush

        input = STDIN.gets
        break if input.nil?

        trimmed = input.strip
        next if trimmed.empty?
        break if trimmed == "exit" || trimmed == "quit"

        # Before expand_prompt on purpose: the skill catalog claims any /name
        # that matches a skill, so a skill called "plan" would shadow /plan.
        if command = ChatCommands.parse(trimmed)
          run_chat_command(command, session_data)
          next
        end

        puts ""
        submit(agent, trimmed)
        puts ""

        session_data.messages = agent.messages
        session_data.usage = agent.cumulative_usage
        session_data.todos = @todos.items
        @session_store.save(session_data)
      end

      puts "Session saved to #{@session_store.session_dir(session_data.id)}/session.json"
      puts "Goodbye! ⚒️"
    end

    private def run_chat_command(command : ChatCommand, session_data : Session::Data) : Nil
      if command.rewind?
        rewind_from_chat(session_data)
        return
      end

      plan = plan_session
      target = command.plan? ? Mode::Plan : Mode::Normal

      if plan.mode == target
        puts "   Already in #{target.to_s.downcase} mode."
        return
      end

      plan.mode = target
    end

    # The chat equivalent of `smith rewind`: undo everything back to the
    # oldest checkpoint of this session, transcript included.
    private def rewind_from_chat(session_data : Session::Data) : Nil
      store = @checkpoints
      entries = store.try(&.list) || [] of Checkpoints::Entry

      if store.nil? || entries.empty?
        puts "   Nothing to rewind."
        return
      end

      result = store.rewind_to(entries.last, force: false)
      result.restored.each { |path| puts "   restored #{path}" }
      result.deleted.each { |path| puts "   deleted  #{path}" }

      unless result.conflicts.empty?
        puts "   ⚠️  changed outside smith, left alone: #{result.conflicts.join(", ")}"
        puts "      use `smith rewind #{session_data.id} --force` to overwrite them"
      end

      unless result.applied?
        puts "   🚫 Nothing was changed."
        return
      end

      if index = result.message_index
        session_data.messages = Session::Transcript.truncate(session_data.messages, index)
        @session_store.save(session_data)
      end

      puts "   ⏪ Rewound. Changes made by bash are not covered."
    end

    # Without this, Ctrl+C kills the process outright and the turn in flight is
    # lost — the loop only persists *after* a completed turn. The handler fires
    # anywhere, including mid provider call and while blocked on STDIN.gets.
    # Session::Store#save writes through AtomicFile, so an interrupt cannot
    # leave a half-written session behind.
    private def install_interrupt_handler(session_data : Session::Data, agent : Agent)
      Signal::INT.trap do
        session_data.messages = agent.messages
        session_data.usage = agent.cumulative_usage
        session_data.todos = @todos.items
        @session_store.save(session_data)

        puts "\n\n⚠️  Interrupted — session saved."
        puts "   Resume with: smith resume #{session_data.id}"
        STDOUT.flush
        exit(130)
      end
    end

    # Both commands work on a saved session, so they resolve the id the same
    # way `resume` does.
    private def resolve_session(session_id : String?) : Session::Data
      data = session_id ? @session_store.load(session_id) : @session_store.latest

      if data.nil?
        STDERR.puts "❌ No sessions found."
        # `smith run` is stateless, so it has no session to hang checkpoints
        # off. Saying so beats leaving the user to guess.
        STDERR.puts "   Checkpoints belong to a session; `smith run` does not create one."
        STDERR.puts "   Use `smith chat` (or `smith resume`) for a run you may want to undo."
        exit(1)
      end

      data
    end

    private def checkpoint_store_for(session : Session::Data) : Checkpoints::Store
      Checkpoints::Store.new(@session_store.session_dir(session.id), enabled: @config.checkpoints.enabled?)
    end

    private def list_checkpoints(session_id : String?)
      session = resolve_session(session_id)
      entries = checkpoint_store_for(session).list

      if entries.empty?
        puts "No checkpoints for session #{session.id}."
        puts "Note: changes made by bash are never snapshotted — see the README."
        return
      end

      puts "🗂️  Checkpoints for #{session.id}:"
      puts "--------------------------------------------------------------------------------"
      printf "%-6s %-20s %-12s %s\n", "ID", "WHEN", "TOOL", "PATH"
      puts "--------------------------------------------------------------------------------"
      entries.each do |entry|
        printf "%-6s %-20s %-12s %s%s\n",
          entry.id,
          entry.created_at.to_s("%Y-%m-%d %H:%M"),
          entry.tool,
          entry.path,
          entry.created? ? "  (created)" : ""
      end
      puts "--------------------------------------------------------------------------------"
      puts "Rewind with: smith rewind #{session.id} --to <ID>"
      puts "Changes made by bash are not covered."
    end

    private def run_rewind(session_id : String?)
      session = resolve_session(session_id)
      store = checkpoint_store_for(session)
      entries = store.list

      if entries.empty?
        puts "Nothing to rewind in session #{session.id}."
        return
      end

      # Without --to this undoes the newest checkpoint only — one invocation,
      # one step back.
      target = if wanted = @rewind_to
                 found = entries.find { |entry| entry.id == wanted || entry.sequence.to_s == wanted }
                 if found.nil?
                   STDERR.puts "❌ Error: no checkpoint '#{wanted}' in session #{session.id}."
                   STDERR.puts "   Known: #{entries.map(&.id).join(", ")}"
                   exit(1)
                 end
                 found
               else
                 entries.last
               end

      undone = entries.count { |entry| entry.sequence >= target.sequence }
      scope = undone == 1 ? "checkpoint #{target.id}" : "checkpoints #{target.id}–#{entries.last.id}"

      result = store.rewind_to(target, force: @force, dry_run: @dry_run)

      if @dry_run
        puts "🔍 Dry run — nothing was changed. Undoing #{scope} would:"
      elsif result.applied?
        puts "⏪ Undid #{scope} — back to the state before #{target.id}."
      else
        puts "🚫 Undoing #{scope} stopped — nothing was changed."
      end

      result.restored.each { |path| puts "   #{result.applied? ? "restored" : "would restore"} #{path}" }
      # Spelled out: the file is gone because it did not exist before this point.
      result.deleted.each { |path| puts "   #{result.applied? ? "deleted " : "would delete"} #{path} (did not exist before #{target.id})" }

      unless result.conflicts.empty?
        puts "\n⚠️  Changed outside smith since the snapshot:"
        result.conflicts.each { |path| puts "   #{path}" }
        puts "   Re-run with --force to overwrite them. The checkpoints are kept until then."
      end

      if result.restored.empty? && result.deleted.empty? && result.conflicts.empty?
        puts "   (no file changes to undo)"
      end

      remaining = store.list.size
      puts "   #{remaining} earlier checkpoint#{remaining == 1 ? "" : "s"} left — run rewind again to go further." if remaining > 0 && result.applied? && !@dry_run

      puts "\nChanges made by bash are not covered by checkpoints."
      return if @dry_run || @files_only || !result.applied?

      if index = result.message_index
        session.messages = Session::Transcript.truncate(session.messages, index)
        @session_store.save(session)
        puts "Transcript cut back to #{session.messages.size} messages."
      end
    end

    private def list_sessions
      entries = @session_store.list
      if entries.empty?
        puts "No saved sessions found under #{@session_store.sessions_dir}"
        return
      end

      puts "📜 Saved Smith Sessions (#{@session_store.sessions_dir}):"
      puts "--------------------------------------------------------------------------------"
      printf "%-28s %-20s %-8s %s\n", "SESSION ID", "UPDATED", "MSGS", "FIRST PROMPT"
      puts "--------------------------------------------------------------------------------"

      entries.each do |e|
        time_str = e.updated_at.to_s("%Y-%m-%d %H:%M")
        printf "%-28s %-20s %-8d %s\n", e.id, time_str, e.message_count, e.first_prompt
      end

      puts "--------------------------------------------------------------------------------"
      puts "To resume a session, run: smith resume <session_id>"
    end
  end
end
