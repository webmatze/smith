require "option_parser"
require "./llm"
require "./tools"
require "./agent"
require "./session"
require "./project_ctx"
require "./skills"
require "./mentions"
require "./agents"
require "./config"
require "./output"
require "./todos"
require "./plan"
require "./chat_commands"
require "./checkpoints"
require "file_utils"
require "./hooks"
require "./trust"
require "./mcp"
require "./ui"

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
    @thinking : Bool? = nil
    @continue : Bool = false
    @max_budget_usd : Float64? = nil
    @trust_hooks : Bool = false
    @hooks : Hooks::Runner? = nil
    @session_id : String = "headless"
    @hook_context : String? = nil
    @checkpoints : Checkpoints::Store? = nil
    @bash_jobs : Tools::BashJobs? = nil
    @mcp : MCP::Manager? = nil
    @rewind_to : String? = nil
    @files_only : Bool = false
    @dry_run : Bool = false
    @force : Bool = false
    @mode : Mode? = nil
    @plan : PlanSession? = nil
    @real_approver : Tools::Approver? = nil
    @tui : Bool? = nil
    # True only once an interactive session actually starts — headless runs
    # keep the plain renderer even on a TTY.
    @interactive_tui : Bool = false
    @tui_app : UI::App? = nil
    @tui_notice_io : IO? = nil
    @tui_warned : Bool = false

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
          str.puts "  resume [<session>]         Resume a session by name or id (default: the latest)"
          str.puts "  continue [<prompt>]        Continue the latest session; same as -c"
          str.puts "  sessions, list             List all saved local chat sessions"
          str.puts "  rename <session> <name>    Give a session a name you can resume by"
          str.puts "  fork <session>             Copy a session so it can be taken two ways"
          str.puts "  context [<session>]        Show where the context window is going"
          str.puts "  checkpoints [<session_id>] List the file snapshots taken during a session"
          str.puts "  rewind [<session_id>]      Undo a session's file changes"
          str.puts "  mcp list | tools <server>  Show the configured MCP servers and their tools\n"
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

        opts.on("--think", "Enable extended thinking (Anthropic)") do
          @thinking = true
        end

        opts.on("--no-think", "Disable extended thinking") do
          @thinking = false
        end

        opts.on("-c", "--continue", "Continue the most recent session; a prompt after it runs headless") do
          @continue = true
        end

        opts.on("--max-budget-usd USD", "Stop the run once the estimated cost reaches this (exit code 2)") do |value|
          budget = value.to_f?
          if budget.nil? || budget <= 0
            STDERR.puts "❌ Error: --max-budget-usd expects a positive number, got #{value.inspect}."
            exit(1)
          end
          @max_budget_usd = budget
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

        opts.on("--tui", "Force the fullscreen terminal UI (interactive sessions)") do
          @tui = true
        end

        opts.on("--no-tui", "Use the plain line renderer instead of the fullscreen UI") do
          @tui = false
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
          puts "  • Sessions: /rename <name> and /context work in chat; costs are shown when the model's price is known."
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

      # -c takes over the dispatch: anything that is not a subcommand becomes
      # the prompt for one more turn on the last session.
      if @continue
        prompt = KNOWN_COMMANDS.includes?(command) ? nil : @args.join(" ")
        run_resume(nil, prompt)
        return
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
        run_resume(@args[1]?)
      when "continue"
        # Everything after the verb is a prompt, so `smith continue "and now
        # the tests"` works the same way `smith -c` does.
        run_resume(nil, @args[1..-1]?.try(&.join(" ")))
      when "sessions", "list"
        list_sessions
      when "rename"
        rename_session(@args[1]?, @args[2..-1]?.try(&.join(" ")))
      when "fork"
        fork_session(@args[1]?)
      when "context"
        show_context(@args[1]?)
      when "checkpoints"
        list_checkpoints(@args[1]?)
      when "rewind"
        run_rewind(@args[1]?)
      when "mcp"
        run_mcp(@args[1]?, @args[2]?)
      else
        prompt = @args.join(" ")
        if prompt.empty?
          run_interactive
        else
          run_headless(prompt)
        end
      end
    end

    KNOWN_COMMANDS = %w[run chat interactive resume continue sessions list checkpoints rewind rename fork context mcp]

    # `run <prompt>`, or a bare prompt with no subcommand — both end up in
    # run_headless.
    private def headless?(command : String) : Bool
      return true if command == "run"
      !KNOWN_COMMANDS.includes?(command) && !@args.join(" ").strip.empty?
    end

    private def renderer : Output::Renderer
      @renderer ||= if @json_output
                      Output::JsonRenderer.new
                    elsif @interactive_tui
                      UI::TuiRenderer.new(tui_app)
                    else
                      Output::HumanRenderer.new
                    end
    end

    # Fullscreen mode is the interactive default on a real terminal; the flags
    # pin it either way. Headless runs never get it, so `smith run` output
    # stays scriptable.
    private def tui_enabled? : Bool
      return false if @json_output
      return false if @tui == false
      return true if STDIN.tty? && STDOUT.tty?

      # --tui asks for fullscreen explicitly. It cannot conjure a terminal to
      # draw on — raw mode needs stdin and stdout to be one — so all it can do
      # here is say why it is downgrading rather than doing so silently.
      if @tui == true && !@tui_warned
        @tui_warned = true
        STDERR.puts "⚠️  --tui needs an interactive terminal; falling back to the line renderer."
      end
      false
    end

    private def tui_app : UI::App
      @tui_app ||= UI::App.new(UI::Terminal.new(
        STDOUT, STDIN,
        color: STDOUT.tty? && ENV["NO_COLOR"]?.nil?
      ))
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
        LLM::OpenAI.new(api_key: require_api_key("OPENAI_API_KEY"), default_model: default_m, timeouts: timeouts, reasoning_effort: @config.reasoning_effort)
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
      system_prompt_parts.map { |part| part[1] }.reject(&.empty?).join("\n\n")
    end

    # The system prompt, still in labelled pieces. `smith context` reports
    # those labels, so it describes the prompt that is actually sent rather
    # than a second assembly that could drift from it.
    private def system_prompt_parts : Array({String, String})
      parts = Array({String, String}).new

      # A definition replaces the built-in preamble outright — the point of
      # --agent is a single-purpose runner, not smith wearing a hat.
      if definition = main_agent
        parts << {"Agent definition", definition.system_prompt}
        parts << {"Hook context", @hook_context.not_nil!} if @hook_context
        return parts
      end

      base_prompt = String.build do |str|
        str.puts "You are Smith, an autonomous coding agent written in Crystal."
        str.puts "\nSkill Storage Policy:"
        str.puts "  • Project-local: .smith/skills/<name>/SKILL.md (recommended for project-specific skills)"
        str.puts "  • Global: ~/.smith/skills/<name>/SKILL.md (available across all user projects)"
        str.puts "When creating a new skill, if the user has not specified the location, ask the user first where they want to store the new skill."
      end

      parts << {"System prompt", base_prompt}

      if plan_session.plan_mode?
        parts << {"Plan mode", <<-PLAN}
        Plan Mode — you are researching, not building:
          • Every mutating tool (bash, write_file, edit_file) is unavailable, and subagents are forced into read-only inspect mode. Do not try to work around that.
          • Understand the code first with read_file, grep and glob.
          • Then call exit_plan_mode with a concrete, step-by-step plan that names the files you intend to change. Writing the plan as prose and stopping does not work — the user only sees it through exit_plan_mode.
          • If the request needs no changes at all, simply answer it.
        PLAN
      end

      parts << {"Skills", @skills_catalog.summary_prompt || ""}
      parts << {"Project (SMITH.md)", ProjectContext.discover || ""}
      parts << {"Hook context", @hook_context || ""}

      # Empty parts stay in the list: `smith context` reports them as zero,
      # which answers "are skills eating my context?" — the join below drops
      # them so the prompt itself is unaffected.
      parts
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
              elsif @interactive_tui
                UI::TuiApprover.new(
                  tui_app,
                  allowlist: approval.allowlist,
                  rules: rules
                )
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

        runner = Hooks::Runner.new(definitions, session_id: @session_id, warn_io: notice_io)
        runner.on_fire = ->(event : Hooks::Event, command : String, blocked : Bool) do
          renderer.handle(Events::HookFired.new(event, command, blocked))
        end
        runner
      end
    end

    private def project_hooks_allowed?(digest : String) : Bool
      project = Config.project_path
      return false if project.nil?

      if @interactive_tui
        UI::TuiTrustPrompt.new(
          tui_app,
          TrustStore.new,
          preapproved: @trust_hooks
        ).allow?(project, digest, @config.hooks.map(&.command))
      else
        TrustPrompt.new(
          TrustStore.new,
          input: STDIN,
          output: renderer.prompt_io,
          preapproved: @trust_hooks
        ).allow?(project, digest, @config.hooks.map(&.command))
      end
    end

    # Job logs live beside the session they belong to. A headless run has no
    # session, so it gets a per-process directory instead — cleaned up when the
    # run ends, along with the jobs themselves.
    private def bash_jobs_dir : String
      return File.join(@session_store.session_dir(@session_id), "bash") unless @session_id == "headless"

      File.join(Dir.tempdir, "smith-bash-#{Process.pid}")
    end

    # Started eagerly at session start, not lazily on first use: `tools/list`
    # has to have answered before the *first* request goes out, or the model
    # never learns the tools exist.
    #
    # A server that will not start is a warning and nothing more — the session
    # continues without its tools.
    private def mcp_manager : MCP::Manager
      @mcp ||= begin
        settings = @config.mcp
        specs = settings.enabled? ? MCP::ServerConfig.discover : Array(MCP::ServerSpec).new

        manager = MCP::Manager.build(specs, timeout: settings.timeout_span)
        manager.start_all(warn_io: notice_io)
        manager
      end
    end

    # Where diagnostics go: under the TUI they belong on screen, otherwise
    # on stderr where they have always been.
    private def notice_io : IO
      return STDERR unless @interactive_tui
      @tui_notice_io ||= UI::NoticeIO.new(tui_app)
    end

    # Same contract as the background jobs below: nothing smith started may
    # outlive it. Servers are spawned processes, and a forgotten one keeps
    # whatever it opened — a database connection, a headless browser.
    private def shutdown_mcp : Nil
      @mcp.try &.shutdown
    end

    # Nothing a session started may outlive it: an orphaned dev server holding
    # its port is a bug, not a feature.
    private def shutdown_bash_jobs : Nil
      jobs = @bash_jobs
      return if jobs.nil?

      running = jobs.running
      unless running.empty?
        if @interactive_tui
          tui_app.notice("🛑 Stopping #{running.size} background job#{running.size == 1 ? "" : "s"}: #{running.map(&.id).join(", ")}")
        else
          puts "\n🛑 Stopping #{running.size} background job#{running.size == 1 ? "" : "s"}: #{running.map(&.id).join(", ")}"
        end
      end

      jobs.shutdown_all
      FileUtils.rm_rf(jobs.dir) if @session_id == "headless" && Dir.exists?(jobs.dir)
    end

    # Only Anthropic implements thinking in the form smith speaks, so asking
    # for it elsewhere would just be an unknown request field.
    private def thinking_enabled? : Bool
      return false unless effective_provider_name.downcase == "anthropic"

      wanted = @thinking
      wanted.nil? ? @config.thinking? : wanted
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
      return UI::TuiPlanGate.new(tui_app) if @interactive_tui

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
      bash = @config.bash
      jobs = (@bash_jobs ||= begin
        created = Tools::BashJobs.new(bash_jobs_dir, max_jobs: bash.max_background_jobs)
        created.on_start = ->(job : Tools::BashJob) do
          renderer.handle(Events::BashJobStarted.new(job.id, job.command))
        end
        created.on_exit = ->(job : Tools::BashJob) do
          renderer.handle(Events::BashJobExited.new(job.id, job.status))
        end
        created
      end)

      web = @config.web

      registry = Tools::Registry.default(
        approver,
        todos: @todos,
        jobs: jobs,
        bash_timeout: bash.timeout,
        max_output_bytes: bash.max_output_bytes,
        web_allow_private: web.allow_private,
        web_max_bytes: web.max_bytes,
        search: Web::SearchProvider.build(web.search_provider, searxng_host: web.searxng_host)
      )
      registry.hooks = hooks
      registry.checkpoints = @checkpoints

      # Before the --agent narrowing below, so a definition can list MCP tools
      # among the ones it wants — and after the built-ins, so a server can
      # never shadow one: the mcp__ prefix keeps them apart, and a collision
      # inside the prefix is resolved by McpTool.register_all.
      Tools::McpTool.register_all(registry, mcp_manager, @config.bash.max_output_bytes)

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
        hooks: hooks,
        thinking_effort: thinking_enabled? ? @config.thinking_effort : nil,
        thinking_budget: thinking_enabled? ? @config.thinking_budget : nil,
        cost_limit_usd: @max_budget_usd,
        rates: budget_rates(provider.name, effective_model)
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

      # Skills first, mentions second: a skill body may itself reference
      # @files, and this way those resolve too. Only one level deep — what a
      # mention pulls in is never scanned again, so a file cannot drag itself
      # back in through a skill.
      expanded = @skills_catalog.expand_prompt(text)

      mentions = Mentions.expand(expanded, Dir.current, @config.mentions)
      if mentions.any?
        renderer.handle(Events::FilesMentioned.new(mentions.files, mentions.skipped))
      end
      expanded = mentions.text

      if context = outcome.additional_context
        expanded = "#{expanded}\n\n#{context}"
      end

      agent.send(expanded)
      true
    end

    private def run_headless(prompt : String)
      provider = build_provider
      effective_model = @model || provider.default_model

      # Headless runs are saved too, so `smith -c "and now the tests"` picks up
      # what just happened rather than an unrelated older chat.
      session_data = @session_store.create(model: effective_model, provider: effective_provider_name)
      @session_id = session_data.id

      agent = build_agent(provider)

      renderer.banner(provider.name, agent.model, @skills_catalog.skills.keys)
      renderer.mcp_banner(mcp_manager.summary)
      # on_mode_change only fires on a *switch*, so the starting mode is
      # announced here — otherwise a --plan run would look like a normal one.
      renderer.handle(Events::ModeChanged.new(Mode::Plan)) if plan_session.plan_mode?

      submit(agent, prompt)
      shutdown_bash_jobs
      shutdown_mcp
      persist(session_data, agent)
      renderer.finish(agent.cumulative_usage, cost_for(provider.name, agent.model, agent.cumulative_usage))

      # A failed provider call must not report success to a calling script.
      exit(renderer.exit_code)
    end

    private def persist(session_data : Session::Data, agent : Agent) : Nil
      session_data.messages = agent.messages
      session_data.usage = agent.cumulative_usage
      session_data.todos = @todos.items
      @session_store.save(session_data)
    end

    private def run_interactive
      @interactive_tui = tui_enabled?
      provider = build_provider
      effective_model = @model || provider.default_model

      session_data = @session_store.create(model: effective_model, provider: effective_provider_name)
      start_session_loop(session_data)
    end

    # `reference` is whatever the user typed — a session name or an id.
    # `prompt` turns the resume into a one-shot: `smith -c "and now the tests"`.
    private def run_resume(reference : String?, prompt : String? = nil)
      session_data = begin
        reference ? @session_store.resolve(reference) : @session_store.latest
      rescue ex : ArgumentError
        STDERR.puts "❌ #{ex.message}"
        exit(1)
      end

      if session_data.nil?
        puts "❌ No sessions found to resume."
        exit(1)
      end

      if prompt && !prompt.strip.empty?
        return resume_headless(session_data, prompt)
      end

      @model = session_data.model
      @provider_name = session_data.provider
      @interactive_tui = tui_enabled?

      if @interactive_tui
        start_session_loop(session_data)
        return
      end

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

    # `smith -c "<prompt>"` — one more turn on the last session, then out.
    # Same shape as run_headless, but the transcript comes from disk and goes
    # back to it.
    private def resume_headless(session_data : Session::Data, prompt : String)
      @model = session_data.model
      @provider_name = session_data.provider
      @session_id = session_data.id

      provider = build_provider(session_data.provider)
      agent = build_agent(provider, session_data.messages)

      renderer.banner(provider.name, agent.model, @skills_catalog.skills.keys)
      renderer.mcp_banner(mcp_manager.summary)
      renderer.handle(Events::ModeChanged.new(Mode::Plan)) if plan_session.plan_mode?

      submit(agent, prompt)
      shutdown_bash_jobs
      shutdown_mcp
      persist(session_data, agent)
      renderer.finish(agent.cumulative_usage, cost_for(session_data.provider, agent.model, agent.cumulative_usage))
      exit(renderer.exit_code)
    end

    private def start_session_loop(session_data : Session::Data)
      # Set before the runner is built, so hooks see the real session id.
      @session_id = session_data.id

      settings = @config.checkpoints
      store = Checkpoints::Store.new(@session_store.session_dir(session_data.id), enabled: settings.enabled?)
      store.prune(max: settings.max_per_session, retention: settings.retention)
      @checkpoints = store

      if @interactive_tui
        run_tui_loop(session_data)
      else
        run_plain_loop(session_data)
      end
    end

    private def run_plain_loop(session_data : Session::Data)
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
      # build_agent has already started them, so this reports what is actually
      # connected rather than what was configured.
      summary = mcp_manager.summary
      puts "   MCP Servers: #{summary.join(", ")}" unless summary.empty?
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
        if invocation = ChatCommands.parse(trimmed)
          run_chat_command(invocation, session_data, agent)
          next
        end

        puts ""
        submit(agent, trimmed)
        puts ""

        persist(session_data, agent)
      end

      shutdown_bash_jobs
      shutdown_mcp
      puts "Session saved to #{@session_store.session_dir(session_data.id)}/session.json"
      puts "Goodbye! ⚒️"
    end

    # The fullscreen session loop. The key loop runs on the main fiber; each
    # submitted turn runs in its own fiber, so the UI keeps drawing (spinner,
    # streaming text, modals) while the agent works.
    private def run_tui_loop(session_data : Session::Data)
      provider = build_provider(session_data.provider)
      agent = build_agent(provider, session_data.messages)

      app = tui_app
      app.model_name = agent.model
      app.mode = plan_session.mode

      tui_banner(session_data, agent)

      # A resumed session replays into the UI instead of being previewed in
      # raw lines — the same transcript, rendered like everything else.
      replay_tui_history(app, session_data)

      @todos.replace(session_data.todos) unless session_data.todos.empty?

      install_interrupt_handler(session_data, agent)

      # The two interrupt stages, driven from the app's key loop.
      app.on_interrupt { agent.stop! }
      app.on_abort do
        # Second press: leave right away; the interrupt handler saves.
        session_data.messages = agent.messages
        session_data.usage = agent.cumulative_usage
        session_data.todos = @todos.items
        @session_store.save(session_data)
        shutdown_bash_jobs
        shutdown_mcp
        exit(130)
      end

      app.run do |text|
        spawn do
          begin
            trimmed = text.strip

            # Before expand_prompt on purpose: the skill catalog claims any
            # /name that matches a skill, so a skill called "plan" would
            # shadow /plan.
            if invocation = ChatCommands.parse(trimmed)
              run_chat_command(invocation, session_data, agent)
              # Slash commands produce notice blocks, not a turn — but the
              # prompt must come back all the same.
              app.turn_finished
            elsif trimmed == "exit" || trimmed == "quit"
              app.quit
            else
              submit(agent, trimmed)
              persist(session_data, agent)
              if cost = cost_for(session_data.provider, agent.model, agent.cumulative_usage)
                app.cost_text = "#{Smith::Pricing.format(cost)}"
              end
              app.turn_finished
            end
          rescue ex : Exception
            renderer.handle(Events::TurnError.new(ex.message || ex.class.name))
            app.turn_finished
          end
        end
      end

      shutdown_bash_jobs
      shutdown_mcp
      persist(session_data, agent)
    end

    private def tui_banner(session_data : Session::Data, agent : Agent) : Nil
      app = tui_app
      # The head — name, version, provider · model, skills — is the renderer's
      # banner, the same one every other mode prints. Only what is specific to
      # an interactive session is added here.
      renderer.banner(session_data.provider, agent.model, @skills_catalog.skills.keys)

      lines = Array(UI::StyledLine).new
      lines << [UI::Span.new("session #{session_data.id[0, 18]}", UI::Style.new(fg: UI::Palette::INFO, dim: true))]

      unless @agents_catalog.agents.empty?
        lines << [UI::Span.new("agents: #{@agents_catalog.agents.keys.join(", ")}", UI::Style.new(fg: UI::Palette::INFO, dim: true))]
      end
      summary = mcp_manager.summary
      unless summary.empty?
        lines << [UI::Span.new("mcp: #{summary.join(", ")}", UI::Style.new(fg: UI::Palette::INFO, dim: true))]
      end
      if definition = main_agent
        lines << [UI::Span.new("running as agent: #{definition.name}", UI::Style.new(fg: UI::Palette::MODE_PLAN))]
      end

      lines << [UI::Span.new("type /help for commands, exit to quit", UI::Style.new(fg: UI::Palette::INFO, dim: true))]
      app.notice(lines)
    end

    # How much of a resumed transcript is replayed into the UI: enough to see
    # where the session left off, not enough to bury the prompt.
    REPLAYED_MESSAGES = 6

    private def replay_tui_history(app : UI::App, session_data : Session::Data) : Nil
      session_data.messages.last(REPLAYED_MESSAGES).each do |msg|
        text = msg.content.select { |b| b.type.text? }.map(&.text).compact.join("\n")
        next if text.strip.empty?

        if msg.role.user?
          app.add_block(UI::UserBlock.new(text), finalize: true)
        else
          block = UI::AssistantBlock.new(text, live: false)
          app.add_block(block, finalize: true)
        end
      end
    end

    private def run_chat_command(invocation : ChatCommands::Invocation, session_data : Session::Data, agent : Agent) : Nil
      command = invocation.command

      if command.rewind?
        rewind_from_chat(session_data)
        return
      end

      if command.context?
        print_context(session_data, agent.messages, agent)
        return
      end

      if command.rename?
        rename_from_chat(session_data, invocation.argument.not_nil!)
        return
      end

      plan = plan_session
      target = command.plan? ? Mode::Plan : Mode::Normal

      if plan.mode == target
        chat_puts("Already in #{target.to_s.downcase} mode.")
        return
      end

      plan.mode = target
    end

    # Text printed by chat commands: lines in the plain loop, notice blocks in
    # the fullscreen one.
    private def chat_puts(text : String) : Nil
      if @interactive_tui
        tui_app.notice(text)
      else
        puts "   #{text}"
      end
    end

    # The chat equivalent of `smith rewind`: undo everything back to the
    # oldest checkpoint of this session, transcript included.
    private def rewind_from_chat(session_data : Session::Data) : Nil
      store = @checkpoints
      entries = store.try(&.list) || [] of Checkpoints::Entry

      if store.nil? || entries.empty?
        chat_puts("Nothing to rewind.")
        return
      end

      result = store.rewind_to(entries.last, force: false)
      result.restored.each { |path| chat_puts("restored #{path}") }
      result.deleted.each { |path| chat_puts("deleted  #{path}") }

      unless result.conflicts.empty?
        chat_puts("⚠️  changed outside smith, left alone: #{result.conflicts.join(", ")}")
        chat_puts("use `smith rewind #{session_data.id} --force` to overwrite them")
      end

      unless result.applied?
        chat_puts("🚫 Nothing was changed.")
        return
      end

      if index = result.message_index
        session_data.messages = Session::Transcript.truncate(session_data.messages, index)
        @session_store.save(session_data)
      end

      chat_puts("⏪ Rewound. Changes made by bash are not covered.")
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
        shutdown_bash_jobs
        # Ctrl+C is exactly where orphans come from: without this the server
        # processes outlive the shell that started smith.
        shutdown_mcp

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

    # `smith mcp list` / `smith mcp tools <server>`. Both really connect: what
    # a server exports is only knowable by asking it, and a listing assembled
    # from the config file alone would answer a different question.
    private def run_mcp(subcommand : String?, argument : String?) : Nil
      case subcommand
      when nil, "list"
        list_mcp_servers
      when "tools"
        list_mcp_tools(argument)
      else
        STDERR.puts "❌ Error: unknown 'smith mcp' subcommand #{subcommand.inspect}."
        STDERR.puts "   Usage: smith mcp list | smith mcp tools <server>"
        exit(1)
      end
    ensure
      shutdown_mcp
    end

    private def list_mcp_servers : Nil
      manager = mcp_manager

      if manager.empty?
        puts "No MCP servers configured."
        puts "   Add them to #{MCP::ServerConfig.global_path} or .smith/#{MCP::ServerConfig::FILE_NAME}:"
        puts %(   {"mcpServers": {"filesystem": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "."]}}})
        return
      end

      puts "🔌 MCP servers:"
      puts "--------------------------------------------------------------------------------"
      printf "%-20s %-10s %-7s %s\n", "SERVER", "STATUS", "TOOLS", "COMMAND"
      puts "--------------------------------------------------------------------------------"

      manager.handles.each do |handle|
        printf "%-20s %-10s %-7s %s\n",
          handle.name,
          handle.running? ? "ready" : "failed",
          handle.tools.size.to_s,
          handle.spec.command_line
      end

      puts "--------------------------------------------------------------------------------"
      manager.handles.reject(&.running?).each { |handle| puts "   #{handle.name}: #{handle.error}" }
      puts "Inspect one with: smith mcp tools <server>"
    end

    private def list_mcp_tools(server : String?) : Nil
      if server.nil?
        STDERR.puts "❌ Error: 'smith mcp tools' needs a server name."
        STDERR.puts "   Known servers: #{mcp_manager.handles.map(&.name).join(", ")}"
        exit(1)
      end

      handle = mcp_manager[server]
      if handle.nil?
        STDERR.puts "❌ Error: no MCP server '#{server}' is configured."
        STDERR.puts "   Known servers: #{mcp_manager.handles.map(&.name).join(", ")}"
        exit(1)
      end

      unless handle.running?
        puts "🚫 #{handle.name} is not running: #{handle.error}"
        return
      end

      puts "🔌 #{handle.name} — #{handle.tools.size} tool#{handle.tools.size == 1 ? "" : "s"}"
      handle.tools.each do |definition|
        puts ""
        puts "   #{MCP::Manager.tool_name(handle.name, definition.name)}"
        puts "      #{definition.description.lines.first? || ""}"
      end
    end

    private def cost_for(provider_name : String, model : String, usage : LLM::Usage) : Float64?
      Pricing.estimate(usage, provider_name, model, @config.pricing)
    end

    # A budget without a price for the model in use is not a budget. Saying so
    # once, loudly, beats letting an automated run believe it is capped.
    private def budget_rates(provider_name : String, model : String) : Pricing::Rates?
      return nil if @max_budget_usd.nil?

      rates = Pricing.rates_for(provider_name, model, @config.pricing)
      if rates.nil?
        STDERR.puts "⚠️  --max-budget-usd cannot apply: no price known for #{provider_name}/#{model}."
        STDERR.puts "   Add one under [pricing.\"#{provider_name}/#{model}\"] to enforce it."
      end

      rates
    end

    private def rename_session(reference : String?, name : String?) : Nil
      if reference.nil? || name.nil? || name.strip.empty?
        STDERR.puts "Error: 'smith rename' needs a session and a name."
        STDERR.puts "Example: smith rename session-1234-abc my-refactor"
        exit(1)
      end

      begin
        session = @session_store.rename(reference, name)
        puts "✏️  Renamed to '#{session.name}' (#{session.id})"
      rescue ex : ArgumentError
        STDERR.puts "❌ #{ex.message}"
        exit(1)
      end
    end

    private def rename_from_chat(session_data : Session::Data, name : String) : Nil
      session = @session_store.rename(session_data.id, name)
      session_data.name = session.name
      chat_puts("✏️  Session renamed to '#{session.name}'.")
    rescue ex : ArgumentError
      chat_puts("❌ #{ex.message}")
    end

    private def fork_session(reference : String?) : Nil
      if reference.nil?
        STDERR.puts "Error: 'smith fork' needs a session to copy."
        STDERR.puts "Example: smith fork my-refactor"
        exit(1)
      end

      begin
        copy = @session_store.fork(reference)
        puts "🍴 Forked #{copy.parent_id} → #{copy.id}#{copy.name.try { |n| " (#{n})" }}"
        puts "   Resume it with: smith resume #{copy.name || copy.id}"
      rescue ex : ArgumentError
        STDERR.puts "❌ #{ex.message}"
        exit(1)
      end
    end

    # `smith context [<session>]` — where the context window actually goes.
    private def show_context(reference : String?) : Nil
      session = begin
        reference ? @session_store.resolve(reference) : @session_store.latest
      rescue ex : ArgumentError
        STDERR.puts "❌ #{ex.message}"
        exit(1)
      end

      if session.nil?
        puts "No sessions found under #{@session_store.sessions_dir}"
        return
      end

      print_context(session, session.messages, nil)
    end

    # Built from the same parts that go into the request, and counted with the
    # same estimator compaction uses — a breakdown that disagreed with the
    # thing it describes would be worse than none.
    private def print_context(session : Session::Data, messages : Array(LLM::Message), agent : Agent?) : Nil
      budget = @config.context.max_tokens
      breakdown = Context::Breakdown.new(budget)

      system_prompt_parts.each { |part| breakdown.add(part[0], part[1]) }
      # The tool set does not vary with who approves it, so the default
      # registry gives the same definitions the run would send.
      breakdown.add("Tool definitions", Tools::Registry.default.specs.to_json)
      breakdown.add("Messages", messages)

      lines = Array(String).new
      lines << "Context for session #{session.reference} (#{format_tokens(budget)} token budget)"
      lines << ""
      breakdown.entries.each do |entry|
        lines << "  %-20s %9s %4d%%" % [entry.label, format_tokens(entry.tokens), breakdown.percent(entry.tokens)]
      end
      lines << "  " + "─" * 35
      lines << "  %-20s %9s %4d%%" % ["Total", format_tokens(breakdown.total), breakdown.percent(breakdown.total)]

      # The live session knows what compaction did to it; a session read back
      # from disk does not, and claiming otherwise would be a guess.
      if agent && agent.compactions > 0
        strategy = agent.last_compaction.try { |s| " (#{s.to_s.downcase})" }
        lines << ""
        lines << "  Compactions this session: #{agent.compactions}#{strategy}"
      end

      if @interactive_tui
        tui_app.notice(lines.map { |text| [UI::Span.new(text, UI::Style.new(fg: UI::Palette::INFO))] of UI::Span })
      else
        lines.each { |line| puts line }
      end
    end

    private def format_tokens(count : Int32) : String
      count.to_s.reverse.gsub(/(\d{3})(?=\d)/, "\\1.").reverse
    end

    private def list_sessions
      entries = @session_store.list
      if entries.empty?
        puts "No saved sessions found under #{@session_store.sessions_dir}"
        return
      end

      puts "📜 Saved Smith Sessions (#{@session_store.sessions_dir}):"
      puts "--------------------------------------------------------------------------------"
      printf "%-28s %-24s %-18s %-6s %s\n", "SESSION ID", "NAME", "UPDATED", "MSGS", "FIRST PROMPT"
      puts "--------------------------------------------------------------------------------"

      entries.each do |e|
        time_str = e.updated_at.to_s("%Y-%m-%d %H:%M")
        printf "%-28s %-24s %-18s %-6d %s\n", e.id, e.name || "-", time_str, e.message_count, e.first_prompt
      end

      puts "--------------------------------------------------------------------------------"
      puts "To resume a session, run: smith resume <name or id>"
    end
  end
end
