require "option_parser"
require "./llm"
require "./tools"
require "./agent"
require "./session"
require "./project_ctx"
require "./skills"
require "./config"

module Smith
  class CLI
    def self.start(args : Array(String))
      new(args).run
    end

    @args : Array(String)
    @model : String? = nil
    @provider_name : String? = nil
    @auto_approve : Bool = false
    @session_store : Session::Store
    @skills_catalog : Skills::Catalog
    @config : Config

    def initialize(@args : Array(String))
      @config = Config.load
      @session_store = Session::Store.new
      @skills_catalog = Skills::Catalog.discover
    end

    # The provider actually in effect: CLI flag (or a resumed session's
    # provider) first, otherwise whatever the config/env/default chain yields.
    private def effective_provider_name : String
      @provider_name || @config.provider
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
          str.puts "  sessions, list             List all saved local chat sessions\n"
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
          puts "  • Persistence: Sessions are saved under ~/.smith/sessions/ and can be resumed with 'smith resume'."
          exit
        end
      end

      parser.parse(@args)

      command = @args.first? || "chat"

      case command
      when "run"
        prompt = @args[1..-1]?.try(&.join(" ")) || ""
        if prompt.empty?
          puts "Error: 'smith run' requires a prompt argument."
          puts "Example: smith run \"Refactor src/smith.cr\""
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
      else
        prompt = @args.join(" ")
        if prompt.empty?
          run_interactive
        else
          run_headless(prompt)
        end
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
        LLM::Anthropic.new(api_key: require_api_key("ANTHROPIC_API_KEY"), default_model: default_m, timeouts: timeouts)
      when "openai"
        LLM::OpenAI.new(api_key: require_api_key("OPENAI_API_KEY"), default_model: default_m, timeouts: timeouts)
      else
        puts "❌ Error: Unknown provider '#{provider_name}'."
        puts "   Known providers: #{Config::BUILTIN_MODELS.keys.join(", ")}"
        exit(1)
      end
    end

    # API keys stay env-only and are never read from the config file, so a
    # plaintext config never becomes a place secrets get committed from.
    private def require_api_key(var_name : String) : String
      api_key = ENV[var_name]?
      if api_key.nil? || api_key.empty?
        puts "❌ Error: #{var_name} environment variable is not set."
        puts "   Please set it via: export #{var_name}=\"your_key_here\""
        exit(1)
      end
      api_key
    end

    private def build_system_prompt : String
      base_prompt = String.build do |str|
        str.puts "You are Smith, an autonomous coding agent written in Crystal."
        str.puts "\nSkill Storage Policy:"
        str.puts "  • Project-local: .smith/skills/<name>/SKILL.md (recommended for project-specific skills)"
        str.puts "  • Global: ~/.smith/skills/<name>/SKILL.md (available across all user projects)"
        str.puts "When creating a new skill, if the user has not specified the location, ask the user first where they want to store the new skill."
      end

      blocks = [base_prompt]

      if skill_summary = @skills_catalog.summary_prompt
        blocks << skill_summary
      end

      if project_instructions = ProjectContext.discover
        blocks << project_instructions
      end

      blocks.join("\n\n")
    end

    # CLI-Flag > [approval] mode. Without a TTY there is nobody to ask, so
    # prompt mode degrades to refusing rather than silently running.
    private def build_approver : Tools::Approver
      return Tools::AutoApprover.new if @auto_approve

      approval = @config.approval
      return Tools::AutoApprover.new if approval.mode.downcase == "auto"
      return Tools::DenyApprover.new unless STDIN.tty?

      Tools::PromptApprover.new(allowlist: approval.allowlist)
    end

    private def build_agent(provider : LLM::Provider, messages : Array(LLM::Message)? = nil) : Agent
      effective_model = @model || provider.default_model

      approver = build_approver
      registry = Tools::Registry.default(approver)
      supervisor = Subagents::Supervisor.new(approver)
      registry.register(Tools::AgentTool.new(supervisor: supervisor, provider: provider, model: effective_model))

      agent = Agent.new(
        provider: provider,
        registry: registry,
        model: effective_model,
        system_prompt: build_system_prompt,
        messages: messages,
        max_context_tokens: @config.context.max_tokens
      )

      agent.on_event do |event|
        case event
        when Events::AssistantText
          print event.text
          STDOUT.flush
        when Events::ToolStart
          puts "\n🔧 Executing tool: \e[33m#{event.tool_name}\e[0m with args: #{event.args.to_json}"
        when Events::ToolFinished
          if event.is_error
            puts "❌ Tool \e[31m#{event.tool_name}\e[0m failed: #{event.result}"
          else
            puts "✅ Tool \e[32m#{event.tool_name}\e[0m finished."
          end
        when Events::HistoryCompacted
          puts "\n🗜️  Context compacted (#{event.strategy}): ~#{event.before_tokens} → ~#{event.after_tokens} tokens"
        when Events::TurnError
          puts "\n❌ Error: #{event.error}"
        end
      end

      agent
    end

    private def run_headless(prompt : String)
      provider = build_provider
      agent = build_agent(provider)
      effective_model = agent.model

      expanded_prompt = @skills_catalog.expand_prompt(prompt)

      puts "⚒️  Running Smith Headless [Provider: #{provider.name} | Model: #{effective_model}]"
      if @skills_catalog.skills.size > 0
        puts "   Loaded Skills: #{@skills_catalog.skills.keys.join(", ")}"
      end
      puts "--------------------------------------------------"
      agent.send(expanded_prompt)
      puts "\n--------------------------------------------------"
      if usage = agent.cumulative_usage
        puts "📊 Usage: #{usage.prompt_tokens} prompt + #{usage.completion_tokens} completion = #{usage.total_tokens} total tokens"
      end
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
      provider = build_provider(session_data.provider)
      agent = build_agent(provider, session_data.messages)
      effective_model = agent.model

      puts "⚒️  Smith LLM Agent Harness v#{Smith::VERSION} (Crystal)"
      puts "   Session: #{session_data.id} | Provider: #{session_data.provider} | Model: #{effective_model}"
      if @skills_catalog.skills.size > 0
        puts "   Loaded Skills: #{@skills_catalog.skills.keys.join(", ")}"
      end
      puts "   Type 'exit' or 'quit' to end session.\n\n"

      install_interrupt_handler(session_data, agent)

      loop do
        print "\n\e[36msmith>\e[0m "
        STDOUT.flush

        input = STDIN.gets
        break if input.nil?

        trimmed = input.strip
        next if trimmed.empty?
        break if trimmed == "exit" || trimmed == "quit"

        expanded_input = @skills_catalog.expand_prompt(trimmed)

        puts ""
        agent.send(expanded_input)
        puts ""

        session_data.messages = agent.messages
        session_data.usage = agent.cumulative_usage
        @session_store.save(session_data)
      end

      puts "Session saved to #{@session_store.sessions_dir}/#{session_data.id}.json"
      puts "Goodbye! ⚒️"
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
        @session_store.save(session_data)

        puts "\n\n⚠️  Interrupted — session saved."
        puts "   Resume with: smith resume #{session_data.id}"
        STDOUT.flush
        exit(130)
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
