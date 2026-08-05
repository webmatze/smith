require "option_parser"
require "./llm"
require "./tools"
require "./agent"
require "./session"
require "./project_ctx"
require "./skills"

module Smith
  class CLI
    def self.start(args : Array(String))
      new(args).run
    end

    @args : Array(String)
    @model : String = "qwen/qwen3.8-max"
    @provider_name : String = "openrouter"
    @session_store : Session::Store
    @skills_catalog : Skills::Catalog

    def initialize(@args : Array(String))
      @session_store = Session::Store.new
      @skills_catalog = Skills::Catalog.discover
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

        opts.on("-m MODEL", "--model=MODEL", "Specify the LLM model (default: qwen/qwen3.8-max)") do |m|
          @model = m
        end

        opts.on("-p PROVIDER", "--provider=PROVIDER", "Specify the provider: openrouter, ollama (default: openrouter)") do |p|
          @provider_name = p
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

    private def build_provider(provider_name : String = @provider_name) : LLM::Provider
      case provider_name.downcase
      when "openrouter"
        api_key = ENV["OPENROUTER_API_KEY"]?
        if api_key.nil? || api_key.empty?
          puts "❌ Error: OPENROUTER_API_KEY environment variable is not set."
          puts "   Please set it via: export OPENROUTER_API_KEY=\"your_key_here\""
          exit(1)
        end
        LLM::OpenRouter.new(api_key: api_key, default_model: @model)
      when "ollama"
        host = ENV["OLLAMA_HOST"]? || "http://localhost:11434"
        default_m = @model == "qwen/qwen3.8-max" ? "gemma4:latest" : @model
        LLM::Ollama.new(host: host, default_model: default_m)
      else
        puts "❌ Error: Unknown provider '#{provider_name}'."
        exit(1)
      end
    end

    private def build_system_prompt : String
      base_prompt = "You are Smith, an autonomous coding agent written in Crystal."

      blocks = [base_prompt]

      if skill_summary = @skills_catalog.summary_prompt
        blocks << skill_summary
      end

      if project_instructions = ProjectContext.discover
        blocks << project_instructions
      end

      blocks.join("\n\n")
    end

    private def build_agent(provider : LLM::Provider, messages : Array(LLM::Message)? = nil) : Agent
      registry = Tools::Registry.default
      supervisor = Subagents::Supervisor.new
      registry.register(Tools::AgentTool.new(supervisor: supervisor, provider: provider, model: @model))

      agent = Agent.new(
        provider: provider,
        registry: registry,
        model: @model,
        system_prompt: build_system_prompt,
        messages: messages
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
        when Events::TurnError
          puts "\n❌ Error: #{event.error}"
        end
      end

      agent
    end

    private def run_headless(prompt : String)
      provider = build_provider
      agent = build_agent(provider)

      expanded_prompt = @skills_catalog.expand_prompt(prompt)

      puts "⚒️  Running Smith Headless [Model: #{@model}]"
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
      session_data = @session_store.create(model: @model, provider: @provider_name)
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
      puts "   Model: #{@model} | Messages: #{session_data.messages.size}"
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

      puts "⚒️  Smith LLM Agent Harness v#{Smith::VERSION} (Crystal)"
      puts "   Session: #{session_data.id} | Model: #{@model}"
      if @skills_catalog.skills.size > 0
        puts "   Loaded Skills: #{@skills_catalog.skills.keys.join(", ")}"
      end
      puts "   Type 'exit' or 'quit' to end session.\n\n"

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
