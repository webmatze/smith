require "option_parser"
require "./llm"
require "./tools"
require "./agent"
require "./session"
require "./session_export"
require "./stats"
require "./transcript_log"
require "./project_ctx"
require "./skills"
require "./mentions"
require "./agents"
require "./config"
require "./output"
require "./presentation"
require "./todos"
require "./plan"
require "./chat_commands"
require "./model_name"
require "./checkpoints"
require "./hooks"
require "./trust"
require "./sandbox"
require "./tools/sandbox_approver"
require "./mcp"
require "./update"
require "./doctor"
require "./marketplace"
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
    @presentation : Presentation? = nil
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
    @sandbox : Sandbox::Strategy? = nil
    @hooks : Hooks::Runner? = nil
    @session_id : String? = nil
    @hook_context : String? = nil
    @checkpoints : Checkpoints::Store? = nil
    @bash_jobs : Tools::BashJobs? = nil
    @mcp : MCP::Manager? = nil
    @rewind_to : String? = nil
    @files_only : Bool = false
    @dry_run : Bool = false
    @force : Bool = false
    @older_than : String? = nil
    @keep_last : Int32 = 0
    @out_path : String? = nil
    @mode : Mode? = nil
    @plan : PlanSession? = nil
    @real_approver : Tools::Approver? = nil
    @tui : Bool? = nil
    # True only once an interactive session actually starts — headless runs
    # keep the plain renderer even on a TTY.
    @interactive_tui : Bool = false
    @tui_app : UI::App? = nil
    @tui_warned : Bool = false
    @update_check : Bool = false
    @allow_unverified : Bool = false

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
        known = @agents_catalog.invocation_names
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
          str.puts "  sessions delete <ref>…     Delete sessions (name or id), files and all"
          str.puts "  sessions export <ref>      Write a session as Markdown (--json, --out <path>)"
          str.puts "  sessions prune             Drop sessions older than --older-than (30d), keeping --keep-last"
          str.puts "  stats                      Total cost and tokens across all saved sessions"
          str.puts "  rename <session> <name>    Give a session a name you can resume by"
          str.puts "  fork <session>             Copy a session so it can be taken two ways"
          str.puts "  context [<session>]        Show where the context window is going"
          str.puts "  checkpoints [<session_id>] List the file snapshots taken during a session"
          str.puts "  rewind [<session_id>]      Undo a session's file changes"
          str.puts "  mcp list | tools <server>  Show the configured MCP servers and their tools"
          str.puts "  skills list                Show the skills catalog: name, origin and description"
          str.puts "  agents list                Show the agent definitions and the model and tools each asks for"
          str.puts "  plugin …                   Marketplaces and plugins: marketplace add|list|remove|update,"
          str.puts "                             install|uninstall|list|update"
          str.puts "  update [--check]           Replace this binary with the newest release binary"
          str.puts "  doctor                     Check providers, MCP, sandbox and config, then exit\n"
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

        opts.on("--dry-run", "rewind / sessions: show what would change, change nothing") do
          @dry_run = true
        end

        opts.on("--force", "rewind: overwrite files changed outside smith since the snapshot") do
          @force = true
        end

        opts.on("--check", "update: report whether a newer release exists, change nothing") do
          @update_check = true
        end

        opts.on("--allow-unverified", "update: install a release that carries no SHA256SUMS anyway") do
          @allow_unverified = true
        end

        opts.on("--older-than SPAN", "sessions prune: drop sessions last updated longer ago (e.g. 30d, 12h, 15m; default 30d)") do |value|
          @older_than = value
        end

        opts.on("--keep-last N", "sessions prune: keep the N most recent regardless of age") do |value|
          count = value.to_i?
          if count.nil? || count < 0
            STDERR.puts "❌ Error: --keep-last expects a non-negative number, got #{value.inspect}."
            exit(1)
          end
          @keep_last = count
        end

        opts.on("--out PATH", "sessions export: write the export to this file instead of stdout") do |value|
          @out_path = value
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

        opts.on("--json", "Emit JSON on stdout: JSON Lines for headless 'run', one document for 'sessions export'") do
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
          puts "    'smith sessions export <ref>' writes a run as Markdown (or --json), to stdout or --out <path>."
          exit
        end
      end

      parser.parse(@args)

      command = @args.first? || "chat"

      # JSON Lines only make sense for a single headless run; anything else
      # would silently do something other than what was asked. `sessions
      # export` is the exception — it answers in JSON too, as one document
      # rather than a stream of events.
      if @json_output && !headless?(command) && !sessions_export?(command)
        STDERR.puts "❌ Error: --json is only supported for headless runs ('smith run') and 'smith sessions export'."
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
        # `smith sessions` lists; the subcommands do the hygiene (#82).
        case @args[1]?
        when "delete"
          delete_sessions(@args[2..-1]?)
        when "export"
          export_session(@args[2..-1]?)
        when "prune"
          prune_sessions
        else
          list_sessions
        end
      when "stats"
        show_stats
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
      when "skills"
        run_skills(@args[1]?)
      when "agents"
        run_agents(@args[1]?)
      when "plugin", "plugins"
        run_plugin(@args[1..-1]? || Array(String).new)
      when "sandbox"
        show_sandbox
      when "update"
        run_update
      when "doctor"
        run_doctor
      else
        prompt = @args.join(" ")
        if prompt.empty?
          run_interactive
        else
          run_headless(prompt)
        end
      end
    end

    KNOWN_COMMANDS = %w[run chat interactive resume continue sessions list checkpoints rewind rename fork context mcp skills agents plugin plugins sandbox stats update doctor]

    private def sessions_export?(command : String) : Bool
      (command == "sessions" || command == "list") && @args[1]? == "export"
    end

    # `run <prompt>`, or a bare prompt with no subcommand — both end up in
    # run_headless.
    private def headless?(command : String) : Bool
      return true if command == "run"
      !KNOWN_COMMANDS.includes?(command) && !@args.join(" ").strip.empty?
    end

    # Everything that differs between the fullscreen UI and plain lines lives
    # behind this one object; see Smith::Presentation. Plain until an
    # interactive session says otherwise, which it does before anything here
    # is asked for.
    private def presentation : Presentation
      @presentation ||= PlainPresentation.new(
        @json_output ? Output::JsonRenderer.new : Output::HumanRenderer.new
      )
    end

    # Called by the two commands that open an interactive session, before a
    # renderer or a gate has been built. Fullscreen mode is the default on a
    # real terminal; the flags pin it either way, and headless runs never get
    # here at all, so `smith run` output stays scriptable.
    private def choose_presentation! : Nil
      # The plain one is built on first use, so anything that asked for a
      # renderer or a gate before this point would have pinned the run to it.
      # Nothing does today; this is here so nothing quietly starts to.
      raise "presentation was built before the session chose one" if @presentation

      @interactive_tui = tui_enabled?
      @presentation = UI::TuiPresentation.new(tui_app) if @interactive_tui
    end

    private def renderer : Output::Renderer
      presentation.renderer
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
      @tui_app ||= UI::App.terminal
    end

    private def build_provider(provider_name : String = effective_provider_name) : LLM::Provider
      name = provider_name.downcase
      # -m wins over the config/env chain; nil means "ask the config".
      default_m = @model || @config.model_for(name)

      http = @config.http
      timeouts = LLM::Timeouts.from_seconds(http.connect_timeout, http.read_timeout)

      case name
      when "openrouter"
        LLM::OpenRouter.new(api_key: require_api_key("OPENROUTER_API_KEY"), default_model: default_m, timeouts: timeouts, cache: @config.cache_for(name))
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
              else
                presentation.approver(approval.allowlist, rules)
              end

      # Inside RuleApprover, in the same seat PromptApprover holds, so the
      # order of authority is unchanged: deny refuses first, allow permits
      # first, and only an unruled command is decided by the sandbox.
      if @config.sandbox.auto_approve? && sandbox.active?
        inner = Tools::SandboxApprover.new(sandbox, inner)
      end

      # Wrapped even when there are no rules, so the composition is the same
      # everywhere; an empty RuleSet decides Unset and costs a hash lookup.
      # Wrapping is also what makes deny survive --yes: the flag only replaces
      # the inner approver.
      Tools::RuleApprover.new(rules, inner)
    end

    # Built once: the profile and the path list are the same for every command
    # of a run, and rebuilding them per call would be work for nothing.
    private def sandbox : Sandbox::Strategy
      @sandbox ||= Sandbox.build(@config.sandbox.policy, Dir.current)
    end

    # Said once, at the start, and never implied. A sandbox that was asked for
    # and is not there must not look like one that is: the whole value of the
    # feature is that the user can stop reading every command, and that is only
    # safe if "on" is trustworthy.
    private def warn_about_sandbox : Nil
      settings = @config.sandbox
      return unless settings.enabled?

      strategy = sandbox
      return if strategy.active?

      STDERR.puts "⚠️  Sandbox #{strategy.describe}."
      STDERR.puts "   [sandbox] required = true refuses bash instead of running it unprotected." unless settings.required?
    end

    # Every entry point opens or resumes a session and assigns this before it
    # builds an agent — and the agent is what first reaches the hooks runner
    # and the bash job directory. There is no run without a session, so rather
    # than carry a sentinel that can never be observed, reading it early is an
    # error.
    private def session_id : String
      @session_id || raise "session id was read before a session was opened"
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

        runner = Hooks::Runner.new(definitions, session_id: session_id, warn_io: notice_io)
        runner.on_fire = ->(event : Hooks::Event, command : String, blocked : Bool) do
          renderer.handle(Events::HookFired.new(event, command, blocked))
        end
        runner
      end
    end

    private def project_hooks_allowed?(digest : String) : Bool
      project = Config.project_path
      return false if project.nil?

      presentation
        .trust_prompt(TrustStore.new, preapproved: @trust_hooks)
        .allow?(project, digest, @config.hooks.map(&.command))
    end

    # Job logs live beside the session they belong to — every run has one,
    # headless included, so there is no second place for them to go.
    private def bash_jobs_dir : String
      File.join(@session_store.session_dir(session_id), "bash")
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
      presentation.notice_io
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
        presentation.say("🛑 Stopping #{running.size} background job#{running.size == 1 ? "" : "s"}: #{running.map(&.id).join(", ")}")
      end

      jobs.shutdown_all
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

      presentation.plan_gate
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

    # Takes the whole session rather than its pieces: passing messages and the
    # calibration ratio separately is how one call site came to carry the
    # transcript without what had been learned about measuring it.
    private def build_agent(provider : LLM::Provider, session_data : Session::Data? = nil) : Agent
      effective_model = @model || main_agent.try(&.model) || provider.default_model

      # Built once and kept, so the [a]lways answers survive a plan-mode
      # detour instead of being asked again afterwards.
      approver = (@real_approver ||= build_approver)
      bash = @config.bash
      jobs = (@bash_jobs ||= begin
        created = Tools::BashJobs.new(bash_jobs_dir, max_jobs: bash.max_background_jobs, sandbox: sandbox)
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
        search: Web::SearchProvider.build(web.search_provider, searxng_host: web.searxng_host),
        max_media_bytes: @config.mentions.max_media_bytes
      )
      registry.hooks = hooks
      registry.checkpoints = @checkpoints

      warn_about_sandbox

      # `required` means what it says: a shell that cannot be confined is not
      # offered at all. Withdrawn rather than left to refuse every call, for
      # the same reason a dead MCP server's tools are withdrawn — a tool that
      # can only fail wastes turns.
      if @config.sandbox.enabled? && @config.sandbox.required? && !sandbox.active?
        registry.unregister("bash")
        registry.unregister("bash_output")
        registry.unregister("bash_kill")
        STDERR.puts "   bash is withdrawn because [sandbox] required = true."
      end

      # Before the --agent narrowing below, so a definition can list MCP tools
      # among the ones it wants — and after the built-ins, so a server can
      # never shadow one: the mcp__ prefix keeps them apart, and a collision
      # inside the prefix is resolved by McpTool.register_all.
      Tools::McpTool.register_all(
        registry,
        mcp_manager,
        @config.bash.max_output_bytes,
        @config.mentions.max_media_bytes
      )

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
      supervisor.max_media_bytes = @config.mentions.max_media_bytes

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
        messages: session_data.try(&.messages),
        context_settings: @config.context,
        context_ratio: session_data.try(&.context_ratio) || 1.0,
        transcript_log: session_data.try { |data| transcript_log_for(data) },
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

      agent.send(expanded, mentions.attachments)
      true
    end

    private def run_headless(prompt : String)
      provider = build_provider
      effective_model = @model || provider.default_model

      # Headless runs are saved too, so `smith -c "and now the tests"` picks up
      # what just happened rather than an unrelated older chat.
      session_data = @session_store.create(model: effective_model, provider: effective_provider_name)
      @session_id = session_data.id
      setup_checkpoints(session_data)

      agent = build_agent(provider, session_data)

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

    # The record of what the session looked like before compaction shortened
    # it, seeded once for a session that predates the log — that is the longest
    # transcript the user has, and otherwise the only one that never gets a raw
    # copy.
    private def transcript_log_for(session_data : Session::Data) : TranscriptLog
      log = TranscriptLog.new(@session_store.session_dir(session_data.id))
      return log if log.exists? || session_data.messages.empty?

      log.seed(session_data.messages)
      announce_first_deep_compaction(session_data, log)
      log
    end

    # A session recorded under the old single-threshold compaction sits just
    # under the ceiling, which is well over the new trigger — so its next turn
    # compacts hard. Said out loud, that reads as the upgrade working; unsaid,
    # it reads as a bug.
    private def announce_first_deep_compaction(session_data : Session::Data, log : TranscriptLog) : Nil
      budget = @config.context.budget(ratio: session_data.context_ratio)
      estimate = budget.charged(Context.estimate_tokens(session_data.messages))
      return if estimate <= budget.trigger_tokens

      presentation.say_block([
        "This session (~#{format_tokens(estimate)} tokens) is past the compaction trigger,",
        "so the next turn will compact it down towards #{format_tokens(budget.target_tokens)}.",
        "The transcript as it stands has been recorded at #{log.path}.",
      ])
    end

    private def persist(session_data : Session::Data, agent : Agent) : Nil
      session_data.messages = agent.messages
      session_data.usage = agent.cumulative_usage
      session_data.todos = @todos.items
      session_data.context_ratio = agent.context_ratio
      @session_store.save(session_data)
    end

    private def run_interactive
      choose_presentation!
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
      choose_presentation!

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
      setup_checkpoints(session_data)

      provider = build_provider(session_data.provider)
      agent = build_agent(provider, session_data)

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

      setup_checkpoints(session_data)

      if @interactive_tui
        run_tui_loop(session_data)
      else
        run_plain_loop(session_data)
      end
    end

    private def run_plain_loop(session_data : Session::Data)
      provider = build_provider(session_data.provider)
      agent = build_agent(provider, session_data)
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
      puts "   Type /help for commands, 'exit' to quit.\n\n"

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
          outcome = run_chat_command(invocation, session_data, agent)
          break if outcome.quit

          # A switched session prints its own header and carries on —
          # activate_session re-points the interrupt handler at it.
          if target = outcome.resume
            persist(session_data, agent)
            provider, agent = activate_session(target, provider)
            session_data = target
            puts "\n🔄 Resumed session '#{target.reference}' (#{target.id})."
          end
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
      agent = build_agent(provider, session_data)

      app = tui_app
      app.completions = chat_completions
      app.model_name = agent.model
      app.mode = plan_session.mode

      tui_banner(session_data, agent)

      # A resumed session replays into the UI instead of being previewed in
      # raw lines — the same transcript, rendered like everything else.
      replay_tui_history(app, session_data)

      @todos.replace(session_data.todos) unless session_data.todos.empty?

      install_interrupt_handler(session_data, agent)

      # The two interrupt stages, driven from the app's key loop. The closures
      # capture the local session_data/agent, which /resume reassigns below —
      # so they always act on the session the loop is currently in.
      app.on_interrupt { agent.stop! }
      app.on_abort do
        # Second press: leave right away; the interrupt handler saves.
        # Through persist rather than by hand: three hand-written copies of
        # this is how context_ratio came to be saved on one path and dropped
        # on the other two.
        persist(session_data, agent)
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
              outcome = run_chat_command(invocation, session_data, agent)

              if outcome.quit
                app.quit
              elsif target = outcome.resume
                # The old session stays saved; the new one takes over the
                # screen — cleared, bannered and replayed like a fresh start.
                # clear! goes first so whatever the switch emits (the target's
                # todo panel among it) lands on the wiped screen.
                persist(session_data, agent)
                app.clear!
                provider, agent = activate_session(target, provider)
                session_data = target

                app.usage_text = ""
                app.cost_text = ""
                tui_banner(session_data, agent)
                replay_tui_history(app, session_data)
                app.notice("🔄 Resumed session '#{target.reference}'.")
              end
              # /model and /resume both change it; every other command leaves
              # it as it was.
              app.model_name = agent.model
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
          app.add_block(UI::UserBlock.new(text))
        else
          block = UI::AssistantBlock.new(text, live: false)
          app.add_block(block)
        end
      end
    end

    # What a chat command decided about the loop itself. Most commands do
    # their thing and leave the loop alone; `/quit` ends it, and `/resume`
    # hands back the session the loop should switch to.
    private record CommandOutcome, quit : Bool = false, resume : Session::Data? = nil

    # Exhaustive on purpose: a command added to ChatCommand without a branch
    # here must fail to compile, rather than fall through to whatever the last
    # `if` happened to be.
    private def run_chat_command(invocation : ChatCommands::Invocation, session_data : Session::Data, agent : Agent) : CommandOutcome
      case invocation.command
      in ChatCommand::Rewind
        rewind_from_chat(session_data)
        CommandOutcome.new
      in ChatCommand::Context
        print_context(session_data, agent.messages, agent)
        CommandOutcome.new
      in ChatCommand::Rename
        rename_from_chat(session_data, invocation.argument.not_nil!)
        CommandOutcome.new
      in ChatCommand::Help
        print_chat_help
        CommandOutcome.new
      in ChatCommand::Clear
        clear_from_chat(agent)
        CommandOutcome.new
      in ChatCommand::Sessions
        print_sessions_list
        CommandOutcome.new
      in ChatCommand::Resume
        CommandOutcome.new(resume: resolve_resume_target(session_data, invocation.argument.not_nil!))
      in ChatCommand::Model
        switch_model(session_data, agent, invocation.argument)
        CommandOutcome.new
      in ChatCommand::Plan
        switch_mode(Mode::Plan)
      in ChatCommand::Normal
        switch_mode(Mode::Normal)
      in ChatCommand::Quit
        CommandOutcome.new(quit: true)
      end
    end

    private def clear_from_chat(agent : Agent) : Nil
      # Order matters in the TUI: the screen wipe drops every block, so the
      # confirmation has to arrive after it to survive.
      agent.clear!
      # A replace on an already empty list would still announce "Todos
      # cleared" — for a clear that cleared nothing.
      @todos.replace(Array(TodoList::Item).new) unless @todos.empty?
      presentation.clear_screen
      chat_puts("🧹 Context cleared.")
    end

    private def switch_mode(target : Mode) : CommandOutcome
      plan = plan_session

      if plan.mode == target
        chat_puts("Already in #{target.to_s.downcase} mode.")
        return CommandOutcome.new
      end

      plan.mode = target
      CommandOutcome.new
    end

    # `/model` — bare it reports what is in use, with a name it switches the
    # model for the rest of the session.
    #
    # Only the name on the wire changes: every request is built from
    # Agent#model, so the provider client keeps its API key and its connection.
    # That is the same thing `-m` does at startup, which is why swapping the
    # *provider* is not offered here — that needs a different client.
    private def switch_model(session_data : Session::Data, agent : Agent, name : String?) : Nil
      if name.nil?
        chat_puts("Model: #{agent.model} | Provider: #{session_data.provider}")
        return
      end

      if reason = ModelName.rejection(name)
        chat_puts("❌ #{reason}")
        return
      end

      if name == agent.model
        chat_puts("Already using #{name}.")
        return
      end

      previous = agent.model
      agent.model = name

      # Persisted as well as applied, so `smith resume` comes back on the new
      # model — the index row is rebuilt from this same field on save.
      session_data.model = name
      # Kept in step so a later /resume, which rebuilds the agent, does not
      # read a stale -m out of the CLI.
      @model = name

      # Subagents are spawned with the model the tool was built with; `-m`
      # reaches them at startup, so a switch has to reach them too.
      if tool = agent.registry.get("agent").as?(Tools::AgentTool)
        tool.model = name
      end

      reprice(session_data.provider, name, agent)

      # Written now rather than when the turn ends: /quit leaves the plain loop
      # without persisting, and the switch has to survive that.
      #
      # Through `save` rather than `persist`: persist copies the agent's live
      # messages over the session's, which would let `/clear` followed by
      # `/model` write an emptied transcript over a saved one. Only the model
      # is meant to change here, and `save` rebuilds the index row from it.
      @session_store.save(session_data)

      chat_puts("🔀 Model: #{previous} → #{name} (#{session_data.provider}). In effect from the next request.")
    end

    # Prices are per model, so a switch re-reads them. Deliberately not through
    # budget_rates: that one writes to STDERR, which would smear the TUI.
    private def reprice(provider_name : String, model : String, agent : Agent) : Nil
      return if @max_budget_usd.nil?

      rates = Pricing.rates_for(provider_name, model, @config.pricing)
      chat_puts("⚠️  No price known for #{provider_name}/#{model}; --max-budget-usd cannot be enforced.") if rates.nil?
      agent.rates = rates
    end

    # Text printed by chat commands: lines in the plain loop, notice blocks in
    # the fullscreen one.
    private def chat_puts(text : String) : Nil
      presentation.say(text)
    end

    # What the popup offers at the prompt: the built-ins, then the skills —
    # both are invoked with a leading slash, and the list is where a human
    # sees that built-ins win over skills of the same name.
    private def chat_completions : Array(UI::Completion)
      entries = ChatCommands.definitions.map do |d|
        UI::Completion.new(
          name: d.verb,
          description: d.description,
          takes_args: d.takes_argument?,
          optional_args: d.arity.optional?
        )
      end

      @skills_catalog.skills.values
        .sort_by(&.name)
        .each do |skill|
          entries << UI::Completion.new(name: "/#{skill.name}", description: skill.description, takes_args: true, builtin: false)
        end

      entries
    end

    private def print_chat_help : Nil
      lines = Array(String).new
      lines << "Chat commands:"
      ChatCommands.definitions.each do |d|
        lines << "  %-20s %s" % [d.usage, d.description]
      end

      unless @skills_catalog.skills.empty?
        lines << ""
        lines << "Skills:"
        @skills_catalog.skills.values
          .sort_by(&.name)
          .each { |skill| lines << "  %-20s %s" % ["/#{skill.name}", skill.description] }
      end

      lines << ""
      lines << "Built-in commands take precedence over skills of the same name."
      presentation.say_block(lines)
    end

    # The in-chat version of `smith sessions`: the same rows, the most recent
    # few of them, so a session to /resume can be picked without leaving the
    # prompt.
    private def print_sessions_list : Nil
      entries = @session_store.list
      if entries.empty?
        chat_puts("No saved sessions under #{@session_store.sessions_dir}.")
        return
      end

      lines = Array(String).new
      lines << "📜 Saved sessions (#{entries.size} total, most recent first):"
      lines << "  " + "-" * 90
      lines << "  %-28s %-24s %-18s %s" % ["SESSION ID", "NAME", "UPDATED", "FIRST PROMPT"]
      lines << "  " + "-" * 90
      lines.concat(session_rows(entries.first(15)))
      lines << "  " + "-" * 90
      lines << "Switch with /resume <name or id>; 'smith sessions' shows all of them."
      presentation.say_block(lines)
    end

    private def session_rows(entries : Array(Session::IndexEntry)) : Array(String)
      entries.map do |e|
        time_str = e.updated_at.to_s("%Y-%m-%d %H:%M")
        "  %-28s %-24s %-18s %s" % [e.id, e.name || "-", time_str, e.first_prompt]
      end
    end

    # `/resume <ref>` from inside a session. nil means "stay where you are":
    # the reference resolved to nothing, or to the session already open.
    private def resolve_resume_target(session_data : Session::Data, reference : String) : Session::Data?
      target = begin
        @session_store.resolve(reference)
      rescue ex : ArgumentError
        chat_puts("❌ #{ex.message}")
        return nil
      end

      if target.id == session_data.id
        chat_puts("Already in session '#{target.reference}'.")
        return nil
      end

      target
    end

    # Everything that has to move when the loop switches sessions mid-run:
    # the session id, the checkpoint store, the hooks runner's session id,
    # the model/provider pair and the agent itself.
    private def activate_session(target : Session::Data, provider : LLM::Provider) : {LLM::Provider, Agent}
      @session_id = target.id
      hooks.session_id = target.id
      setup_checkpoints(target)

      # The resumed session decides model and provider, the same way
      # `smith resume` does — a -m from the original start does not follow.
      # Both are set before the provider is rebuilt: build_provider reads @model.
      @model = target.model
      @provider_name = target.provider
      provider = build_provider(target.provider) unless provider.name.downcase == target.provider.downcase
      agent = build_agent(provider, target)
      @todos.replace(target.todos)

      # The trap's closure captured the session it was installed for — it
      # must persist the new one when ^C lands after a /resume.
      install_interrupt_handler(target, agent)

      {provider, agent}
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

      if index = rewind_cut(result, session_data.messages)
        session_data.messages = Session::Transcript.truncate(session_data.messages, index)
        @session_store.save(session_data)
      end

      chat_puts("⏪ Rewound. #{bash_note("Changes made by bash are not covered.")}")
    end

    # Without this, Ctrl+C kills the process outright and the turn in flight is
    # lost — the loop only persists *after* a completed turn. The handler fires
    # anywhere, including mid provider call and while blocked on STDIN.gets.
    # Session::Store#save writes through AtomicFile, so an interrupt cannot
    # leave a half-written session behind.
    private def install_interrupt_handler(session_data : Session::Data, agent : Agent)
      Signal::INT.trap do
        # Through persist rather than by hand: three hand-written copies of
        # this is how context_ratio came to be saved on one path and dropped
        # on the other two.
        persist(session_data, agent)
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

    # Both commands work on a saved session, so they resolve the reference the
    # same way `resume` does — through the store, which is what makes a name
    # work here as well as an id, and what refuses a reference that is really
    # a path. It used to call `load` directly, so it did neither.
    private def resolve_session(reference : String?) : Session::Data
      data = begin
        reference ? @session_store.resolve(reference) : @session_store.latest
      rescue ex : ArgumentError
        STDERR.puts "❌ #{ex.message}"
        exit(1)
      end

      if data.nil?
        STDERR.puts "❌ No sessions found."
        # Checkpoints hang on a session, and every run creates one — so the
        # only way to get here is to have no runs at all yet.
        STDERR.puts "   Checkpoints belong to a session, and nothing has been run yet."
        exit(1)
      end

      data
    end

    # Where a rewind cuts the transcript, as the checkpoint named it: by
    # message id, or by the raw index for checkpoints written before ids
    # existed. nil means the message is gone and the transcript stays as it is.
    private def rewind_cut(result : Checkpoints::RestoreResult, messages : Array(LLM::Message)) : Int32?
      if id = result.message_id
        Session::Transcript.index_after(messages, id)
      else
        result.message_index
      end
    end

    private def checkpoint_store_for(session : Session::Data) : Checkpoints::Store
      Checkpoints::Store.new(@session_store.session_dir(session.id), enabled: @config.checkpoints.enabled?)
    end

    # Hangs the store on the session directory and puts it where build_agent
    # picks it up, so it has to run before that call.
    #
    # Every start path goes through here — the interactive loop as much as
    # `smith run` and `smith -c`. It lived inline in the interactive setup
    # once, which is exactly why the two headless paths spent their lives
    # writing files no checkpoint covered. Pruning belongs in the same place:
    # a headless session that never pruned grows without limit.
    private def setup_checkpoints(session_data : Session::Data) : Nil
      settings = @config.checkpoints

      # Session hygiene rides the same chokepoint (#82): the session being
      # started is protected explicitly, so a resume cannot expire itself.
      @session_store.prune(older_than: @config.sessions.retention, protect: session_data.id)

      @checkpoints = Checkpoints::Store.open(
        @session_store.session_dir(session_data.id),
        enabled: settings.enabled?,
        max: settings.max_per_session,
        retention: settings.retention
      )
    end

    # The bash limit, with somewhere to go when there is somewhere to go.
    #
    # `bash` is deliberately never snapshotted — what a shell command touches
    # is not predictable, and a rewind that claims more than it delivers is
    # worse than none (#62). Inside a git repo there is a real answer to point
    # at, so the limit arrives with one instead of only being a limit.
    private def bash_note(lead : String) : String
      # A confined command could not have written outside the sandbox's paths,
      # so the gap this sentence warns about is smaller when one is on — but
      # it is still a gap, because inside those paths bash was free.
      lead += " With [sandbox] on, it could only write inside the sandbox's paths." if sandbox.active?

      return lead if Smith.git_root(Dir.current).nil?

      "#{lead} `git diff` shows what a command changed since your last commit."
    end

    # The whole of it lives in Smith::Update — replacing the running binary is
    # its own problem, and it is testable only away from the CLI.
    private def run_update : Nil
      code = Update::Command.new(check_only: @update_check, allow_unverified: @allow_unverified).run
      exit(code) unless code.zero?
    end

    # Every source a run depends on, checked before a session exists. No
    # provider is built and no request is sent: build_provider exits on a
    # missing key, and a missing key is precisely what this reports.
    private def run_doctor : Nil
      provider = effective_provider_name.downcase

      report = Doctor::Runner.new(
        config: @config,
        provider: provider,
        model: @model || @config.model_for(provider),
        mode: effective_mode.to_s.downcase,
        skills: @skills_catalog.skills.size,
        agents: @agents_catalog.agents.size,
        # From the catalogs already built, not a second walk of the same
        # directories: a count on its own hides the file that failed to load.
        catalog_notes: Doctor.catalog_notes(@skills_catalog, @agents_catalog)
      ).run

      Doctor.render(report, STDOUT)
      exit(report.exit_code)
    end

    # What is actually in force, printable. A sandbox nobody can inspect is a
    # claim, and the value of this feature is that the claim can be relied on.
    private def show_sandbox
      settings = @config.sandbox
      strategy = sandbox

      puts "🧰 Sandbox: #{strategy.describe}"

      unless settings.enabled?
        puts "   Set [sandbox] enabled = true to confine bash."
        return
      end

      if strategy.is_a?(Sandbox::MacOS)
        puts
        puts "   Writable:"
        strategy.write_paths.each { |path| puts "     #{path}" }

        unless strategy.deny_read.empty?
          puts
          puts "   Unreadable:"
          strategy.deny_read.each { |path| puts "     #{path}" }
        end

        unless settings.policy.unsandboxed.empty?
          puts
          puts "   Runs unconfined ([sandbox] unsandboxed):"
          settings.policy.unsandboxed.each { |entry| puts "     #{entry}" }
        end

        puts
        puts "   Everything else is readable; nothing else is writable."
        puts "   Approval is skipped for confined commands ([sandbox] auto_approve)." if settings.auto_approve?
        puts "   Hostnames cannot be filtered — SBPL matches addresses and ports only." if strategy.policy.network.ports?
      end

      puts
      puts "   write_file and edit_file are not covered: they run inside smith, not in the sandbox."
    end

    private def list_checkpoints(session_id : String?)
      session = resolve_session(session_id)
      entries = checkpoint_store_for(session).list

      if entries.empty?
        puts "No checkpoints for session #{session.id}."
        puts bash_note("Note: changes made by bash are never snapshotted — see the README.")
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
      puts bash_note("Changes made by bash are not covered.")
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

      puts "\n#{bash_note("Changes made by bash are not covered by checkpoints.")}"
      return if @dry_run || @files_only || !result.applied?

      if index = rewind_cut(result, session.messages)
        session.messages = Session::Transcript.truncate(session.messages, index)
        @session_store.save(session)
        puts "Transcript cut back to #{session.messages.size} messages."
      else
        # Say it rather than leave the files and the transcript quietly out of
        # step: the message this checkpoint named was compacted away.
        puts "Transcript left alone — compaction replaced the message this checkpoint pointed at."
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
          # An `--api-key` in the argument list and a token in a url are both
          # ordinary ways to configure a server, and this listing is one of
          # the things people paste into a bug report.
          handle.spec.safe_description
      end

      puts "--------------------------------------------------------------------------------"
      # The full error, stderr and all: here the question is why a server will
      # not start, and its own complaint is the answer. `smith doctor` takes
      # the summary instead.
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

    # `smith plugin …` — marketplaces and the plugins installed from them. The
    # work is in Smith::Marketplace; what belongs here is the verb, the exit
    # code and the one place a refusal is printed.
    private def run_plugin(arguments : Array(String)) : Nil
      Marketplace::Commands.new.dispatch(arguments)
    rescue ex : Marketplace::Error
      STDERR.puts "❌ Error: #{ex.message}"
      exit(1)
    end

    private def run_skills(subcommand : String?) : Nil
      case subcommand
      when nil, "list"
        list_skills
      else
        STDERR.puts "❌ Error: unknown 'smith skills' subcommand #{subcommand.inspect}."
        STDERR.puts "   Usage: smith skills list"
        exit(1)
      end
    end

    # The catalog exactly as the model gets it: what loaded, which file it came
    # from, and what its frontmatter says. A skill whose header could not be
    # read loads anyway, so the warnings below the list are the only place that
    # says so — without them a `$skill-name` that quietly fails to expand has no
    # explanation.
    private def list_skills : Nil
      catalog = @skills_catalog
      # Derived from every source at once, so read it once rather than rebuild
      # it per use.
      warnings = catalog.warnings

      # Both clauses matter: a file that could not be read at all warns without
      # ever becoming a skill.
      if catalog.skills.empty? && warnings.empty?
        puts "No skills found."
        puts "   Add one at .smith/skills/<name>/SKILL.md, or globally at #{File.join(Smith.home_dir, "skills")}/<name>/SKILL.md."
        return
      end

      puts "🧩 Skills (#{catalog.skills.size}):"

      catalog.skills.values.sort_by(&.name).each do |skill|
        puts
        puts "   #{skill.name}"
        puts "      path:        #{skill.path}"
        # Where a skill came from, for the ones that did not come from a
        # directory the reader chose: a plugin skill is invoked by its
        # namespaced name, and the bare form only works when nothing else
        # claims it.
        if plugin = skill.plugin
          puts "      origin:      plugin #{plugin}@#{skill.marketplace}"
          puts "      also:        /#{skill.bare_name}, $#{skill.bare_name}" if catalog.bare_aliases[skill.bare_name]? == skill.name
        end
        puts "      description: #{skill.description}"
        # Which source won a name clash is otherwise nowhere visible, and the
        # warnings below refer to files that may be the ones that lost.
        catalog.shadowed[skill.name]?.try(&.each { |lost| puts "      shadows:     #{lost}" })
      end

      unless warnings.empty?
        puts
        warnings.each { |warning| puts warning }
      end

      puts
      puts "Read from .smith/skills/, .gemini/skills/, .agents/skills/, #{File.join(Smith.home_dir, "skills")}/ and installed plugins."
      puts "Invoke one in chat with /<name>, or reference it in a prompt as $<name>. A plugin skill is always /<plugin>:<name>."
    end

    private def run_agents(subcommand : String?) : Nil
      case subcommand
      when nil, "list"
        list_agents
      else
        STDERR.puts "❌ Error: unknown 'smith agents' subcommand #{subcommand.inspect}."
        STDERR.puts "   Usage: smith agents list"
        exit(1)
      end
    end

    # Every definition, and what it actually asks for. `tools` is the effective
    # list, since a definition that names none still gets the set its mode
    # implies — printing only what the file said would hide the difference.
    private def list_agents : Nil
      catalog = @agents_catalog

      if catalog.agents.empty?
        puts "No agent definitions found."
        puts "   Add one at .smith/agents/<name>.md, or globally at #{File.join(Smith.home_dir, Agents::Catalog::DIRECTORY_NAME)}/<name>.md."
        return
      end

      puts "🤖 Agents (#{catalog.agents.size}):"

      catalog.agents.values.sort_by(&.name).each do |agent|
        mode = agent.mode.to_s.downcase
        configured = agent.tools

        # An empty `tools:` is a real configuration — an agent that may call
        # nothing — and must not render as a blank line.
        tools =
          if configured.nil?
            "#{agent.tool_names.join(", ")} (default for mode '#{mode}')"
          elsif configured.empty?
            "(none)"
          else
            configured.join(", ")
          end

        puts
        puts "   #{agent.name}"
        puts "      path:        #{agent.path}"
        if plugin = agent.plugin
          puts "      origin:      plugin #{plugin}@#{agent.marketplace}"
          puts "      also:        #{agent.bare_name}" if catalog.bare_aliases[agent.bare_name]? == agent.name
        end
        puts "      description: #{agent.description}"
        puts "      provider:    #{agent.provider || "(inherited)"}"
        puts "      model:       #{agent.model || "(inherited)"}"
        puts "      mode:        #{mode}"
        puts "      tools:       #{tools}"
        # Which source won a name clash is otherwise nowhere visible, and a
        # warning on stderr may name the file that lost.
        catalog.shadowed[agent.name]?.try(&.each { |lost| puts "      shadows:     #{lost}" })
      end

      puts
      puts "Delegate to one with the agent tool's agent_type, or run one directly: smith --agent <name> run \"…\""
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
      budget = @config.context.budget(ratio: session.context_ratio)
      breakdown = Context::Breakdown.new(budget)

      system_prompt_parts.each { |part| breakdown.add(part[0], part[1]) }

      # A session read back from disk does not record which MCP servers were
      # connected, so the current tool set is the closest honest answer — said
      # out loud rather than passed off as what the session actually sent.
      registry = agent.try(&.registry) || Tools::Registry.default
      tools_label = agent ? "Tool definitions" : "Tool definitions*"
      breakdown.add(tools_label, registry.specs.to_json)
      breakdown.add_history("Messages", messages)

      lines = Array(String).new
      lines << "Context for session #{session.reference} (#{format_tokens(budget.max_tokens)} token budget)"
      lines << ""
      # Charged, like the total: rows that did not add up to the line beneath
      # them would be exactly the disagreement this breakdown exists to avoid.
      breakdown.entries.each do |entry|
        tokens = breakdown.charged(entry.tokens)
        lines << "  %-20s %9s %4d%%" % [entry.label, format_tokens(tokens), breakdown.percent(tokens)]
      end
      lines << "  " + "─" * 35
      total = breakdown.charged_total
      lines << "  %-20s %9s %4d%%" % ["Total", format_tokens(total), breakdown.percent(total)]
      lines << ""
      lines << "  Compacts at %s (%d%%), down to %s (%d%%)" % [
        format_tokens(budget.trigger_tokens), breakdown.percent(budget.trigger_tokens),
        format_tokens(budget.target_tokens), breakdown.percent(budget.target_tokens),
      ]
      lines << "  * current tool set, not the one this session ran with" if agent.nil?

      # The live session knows what compaction did to it; a session read back
      # from disk does not, and claiming otherwise would be a guess.
      if agent && agent.compactions > 0
        strategy = agent.last_compaction.try { |s| " (#{s.to_s.downcase})" }
        lines << ""
        lines << "  Compactions this session: #{agent.compactions}#{strategy}"
      end

      presentation.say_block(lines)
    end

    private def format_tokens(count : Int32) : String
      count.to_s.reverse.gsub(/(\d{3})(?=\d)/, "\\1.").reverse
    end

    # `smith sessions delete <ref>…` — removes a session completely: index
    # entry, directory with checkpoints and logs, legacy file if one exists.
    # One bad reference must not stop the rest from going; --dry-run lists
    # what would be removed without removing it.
    private def delete_sessions(references : Array(String)?) : Nil
      if references.nil? || references.empty?
        STDERR.puts "Error: 'smith sessions delete' needs at least one session (name or id)."
        STDERR.puts "Example: smith sessions delete my-refactor"
        exit(1)
      end

      warn_about_index_damage

      doomed = Array(String).new
      errors = Array(String).new

      references.each do |reference|
        entry = if @dry_run
                  @session_store.resolve_entry(reference)
                else
                  @session_store.delete(reference)
                end
        doomed << (entry.try { |e| "#{e.name || e.id} (#{e.id})" } || reference)
      rescue ex : ArgumentError
        errors << ex.message.not_nil!
      end

      verb = @dry_run ? "Would delete" : "Deleted"
      doomed.each { |label| puts "🗑️  #{verb} #{label}" }
      errors.each { |message| STDERR.puts "❌ #{message}" }

      exit(1) unless errors.empty?
    end

    # `smith sessions export <ref>` — a run you can take with you: Markdown to
    # read, `--json` for the structured log, `--out` for a file (#95).
    #
    # Nothing on this path builds a provider or needs an API key: an export is
    # a view over files that are already on disk.
    private def export_session(references : Array(String)?) : Nil
      reference = references.try(&.first?)

      if reference.nil?
        STDERR.puts "Error: 'smith sessions export' needs a session (name or id)."
        STDERR.puts "Example: smith sessions export my-refactor --out run.md"
        exit(1)
      end

      # One session per export: silently ignoring the rest would export
      # something other than what was asked for.
      if references && references.size > 1
        STDERR.puts "Error: 'smith sessions export' takes one session, got #{references.size}: #{references.join(", ")}."
        STDERR.puts "Export them one at a time, each with its own --out."
        exit(1)
      end

      document = begin
        SessionExport.build(@session_store, reference, @config.pricing)
      rescue ex : ArgumentError
        STDERR.puts "❌ #{ex.message}"
        exit(1)
      end

      # Damage goes to stderr so stdout stays the document and can be piped.
      document.warnings.each { |warning| STDERR.puts "⚠️  #{warning}" }

      content = @json_output ? document.to_json_document : document.to_markdown

      if path = @out_path
        # AtomicFile creates the directories its own callers need; an export
        # goes where the user pointed, so a typo has to be an error rather
        # than a tree of empty directories.
        parent = File.dirname(path)
        unless Dir.exists?(parent)
          STDERR.puts "❌ Could not write the export to #{path}: the directory #{parent} does not exist."
          exit(1)
        end

        begin
          # Atomic, like everything else smith writes: half an export is worse
          # than none.
          AtomicFile.write(path, content)
        rescue ex : File::Error | IO::Error
          STDERR.puts "❌ Could not write the export to #{path}: #{ex.message}"
          exit(1)
        end
        puts "📄 Exported #{document.reference} (#{document.messages.size} message(s)) to #{path}"
      else
        begin
          # Unbuffered, so a closed pipe surfaces here with nothing left to
          # flush at exit. `smith sessions export … | head -1` is how a long
          # export gets read, and it must not end in a stack trace.
          STDOUT.sync = true
          STDOUT.puts content
        rescue IO::Error
          # The reader went away. The export is fine; there is nobody to
          # hand it to.
        end
      end
    end

    # `smith sessions prune` — drops every session last updated before the
    # cutoff, but never the newest one and never the --keep-last most recent.
    private def prune_sessions : Nil
      warn_about_index_damage
      input = @older_than || "30d"

      older_than = begin
        Session::Retention.parse(input)
      rescue ex : ArgumentError
        STDERR.puts "❌ #{ex.message}"
        exit(1)
      end

      doomed = @session_store.prune(older_than: older_than, keep_last: @keep_last, dry_run: @dry_run)

      if doomed.empty?
        puts "Nothing to prune — no session is older than #{input}."
        puts "   The newest session is never pruned."
        return
      end

      if @dry_run
        puts "🔍 Dry run — nothing was deleted. #{doomed.size} session(s) would go:"
      else
        puts "🧹 Pruned #{doomed.size} session(s) older than #{input}:"
      end

      doomed.each do |entry|
        printf "   %-28s %-24s updated %s\n", entry.id, entry.name || "-", entry.updated_at.to_s("%Y-%m-%d %H:%M")
      end

      remaining = @session_store.list.size
      puts "   #{remaining} session(s) #{(@dry_run ? "would remain" : "left")}; the newest one is never pruned."
    end

    # The index entries, with anything unreadable in the file named on stderr.
    #
    # A listing or a total that is quietly one session short is worse than an
    # error, because nothing about it looks wrong. The store already knows
    # what it could not parse; every command built on the index says so.
    private def index_entries : Array(Session::IndexEntry)
      entries, damage = @session_store.read_index
      damage.each { |problem| STDERR.puts "⚠️  The session index is damaged: #{problem}." }
      entries
    end

    # For the commands that work through the store and never hold the entries
    # themselves. `delete` and `prune` need this most of all: they are the
    # destructive ones, and a purge that quietly drops what it could not read
    # is the worst version of a silent index.
    private def warn_about_index_damage : Nil
      index_entries
    end

    private def list_sessions
      entries = index_entries
      if entries.empty?
        puts "No saved sessions found under #{@session_store.sessions_dir}"
        return
      end

      puts "📜 Saved Smith Sessions (#{@session_store.sessions_dir}):"
      puts "--------------------------------------------------------------------------------"
      printf "%-28s %-24s %-18s %-6s %-8s %s\n", "SESSION ID", "NAME", "UPDATED", "MSGS", "COST", "FIRST PROMPT"
      puts "--------------------------------------------------------------------------------"

      entries.each do |e|
        time_str = e.updated_at.to_s("%Y-%m-%d %H:%M")
        # `n/a` when no rate is known — never a guess (see Pricing).
        cost_str = Pricing.format(e.cost(@config.pricing))
        printf "%-28s %-24s %-18s %-6d %-8s %s\n", e.id, e.name || "-", time_str, e.message_count, cost_str, e.first_prompt
      end

      puts "--------------------------------------------------------------------------------"
      puts "To resume a session, run: smith resume <name or id>"
    end

    # `smith stats` — totals across every saved session, built from the
    # index alone. Read-only by construction: nothing here writes (#85).
    private def show_stats
      entries = index_entries
      if entries.empty?
        puts "No sessions found under #{@session_store.sessions_dir}"
        puts "Start a chat (`smith chat`) or a headless run, and the totals land here."
        return
      end

      agg = Stats.aggregate(entries, @config.pricing)

      puts "📊 Smith usage across #{agg.sessions} session(s):"
      puts "--------------------------------------------------------------------------------"
      puts "  Total cost:        #{Pricing.format(agg.cost)}"
      puts "  Total tokens:      #{agg.total_tokens} (#{agg.prompt_tokens} prompt + #{agg.completion_tokens} completion + #{agg.cached_tokens} cache)"
      puts "  Sessions w/ usage: #{agg.with_usage} of #{agg.sessions}"
      puts
      printf "  %-40s %8s %12s %10s\n", "PROVIDER/MODEL", "SESSIONS", "TOKENS", "COST"
      puts "  " + ("-" * 74)
      agg.by_model.each do |m|
        printf "  %-40s %8d %12d %10s\n", m.label, m.sessions, m.tokens, Pricing.format(m.cost)
      end
    end
  end
end
