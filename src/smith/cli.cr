require "option_parser"
require "./llm"
require "./tools"
require "./agent"

module Smith
  class CLI
    def self.start(args : Array(String))
      new(args).run
    end

    @args : Array(String)
    @model : String = "anthropic/claude-3.5-sonnet"
    @provider_name : String = "openrouter"

    def initialize(@args : Array(String))
    end

    def run
      parser = OptionParser.parse(@args) do |opts|
        opts.banner = "Usage: smith [command] [options]"

        opts.on("-m MODEL", "--model=MODEL", "Specify the LLM model to use (default: anthropic/claude-3.5-sonnet)") do |m|
          @model = m
        end

        opts.on("-p PROVIDER", "--provider=PROVIDER", "Specify the provider (default: openrouter)") do |p|
          @provider_name = p
        end

        opts.on("-v", "--version", "Print version") do
          puts "smith version #{Smith::VERSION}"
          exit
        end

        opts.on("-h", "--help", "Show help") do
          puts opts
          exit
        end
      end

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
      else
        # If command is not recognized, treat as headless prompt if provided
        prompt = @args.join(" ")
        if prompt.empty?
          run_interactive
        else
          run_headless(prompt)
        end
      end
    end

    private def build_provider : LLM::Provider
      case @provider_name.downcase
      when "openrouter"
        api_key = ENV["OPENROUTER_API_KEY"]?
        if api_key.nil? || api_key.empty?
          puts "❌ Error: OPENROUTER_API_KEY environment variable is not set."
          puts "   Please set it via: export OPENROUTER_API_KEY=\"your_key_here\""
          exit(1)
        end
        LLM::OpenRouter.new(api_key: api_key, default_model: @model)
      else
        puts "❌ Error: Unknown provider '#{@provider_name}'."
        exit(1)
      end
    end

    private def build_agent(provider : LLM::Provider) : Agent
      registry = Tools::Registry.default
      agent = Agent.new(
        provider: provider,
        registry: registry,
        model: @model
      )

      # Attach CLI event listeners for ANSI progress rendering
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
            summary = event.result.lines.first? || "(empty output)"
            puts "✅ Tool \e[32m#{event.tool_name}\e[0m finished."
          end
        when Events::TurnError
          puts "\n❌ Error: #{event.error}"
        when Events::UsageUpdated
          u = event.usage
          # Silent or debug log
        end
      end

      agent
    end

    private def run_headless(prompt : String)
      provider = build_provider
      agent = build_agent(provider)

      puts "⚒️  Running Smith Headless [Model: #{@model}]"
      puts "--------------------------------------------------"
      agent.send(prompt)
      puts "\n--------------------------------------------------"
      if usage = agent.cumulative_usage
        puts "📊 Usage: #{usage.prompt_tokens} prompt + #{usage.completion_tokens} completion = #{usage.total_tokens} total tokens"
      end
    end

    private def run_interactive
      provider = build_provider
      agent = build_agent(provider)

      puts "⚒️  Smith LLM Agent Harness v#{Smith::VERSION} (Crystal)"
      puts "   Model: #{@model} | Provider: #{@provider_name}"
      puts "   Type 'exit' or 'quit' to end session.\n\n"

      loop do
        print "\n\e[36msmith>\e[0m "
        STDOUT.flush

        input = ARGF.gets
        break if input.nil?

        trimmed = input.strip
        next if trimmed.empty?
        break if trimmed == "exit" || trimmed == "quit"

        puts ""
        agent.send(trimmed)
        puts ""
      end

      puts "Goodbye! ⚒️"
    end
  end
end
