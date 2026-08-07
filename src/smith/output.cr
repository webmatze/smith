require "json"
require "./events"
require "./llm/types"

module Smith::Output
  # Turns the agent's event stream into something for a consumer to read —
  # either a human at a terminal or a script parsing stdout.
  #
  # Both implementations take their IOs so specs can drive them against
  # IO::Memory instead of a real terminal.
  abstract class Renderer
    abstract def handle(event : Events::Event) : Nil
    abstract def banner(provider : String, model : String, skills : Array(String)) : Nil
    abstract def finish(usage : LLM::Usage) : Nil

    # Where an approval prompt should write. In JSON mode this must not be
    # stdout, or the prompt would land in the middle of the JSONL stream.
    abstract def prompt_io : IO

    # A failed provider call must not report success. Tool errors deliberately
    # do not count — a failing grep is ordinary agent flow that the model
    # handles itself.
    getter? failed : Bool = false

    def exit_code : Int32
      failed? ? 1 : 0
    end

    # Assistant text arrives one block at a time, so the complete answer is
    # only known once the turn ends.
    @answer = String::Builder.new

    def answer : String
      @answer.to_s
    end
  end

  class HumanRenderer < Renderer
    def initialize(@io : IO = STDOUT)
    end

    def prompt_io : IO
      @io
    end

    def banner(provider : String, model : String, skills : Array(String)) : Nil
      @io.puts "⚒️  Running Smith Headless [Provider: #{provider} | Model: #{model}]"
      @io.puts "   Loaded Skills: #{skills.join(", ")}" unless skills.empty?
      @io.puts "--------------------------------------------------"
    end

    def handle(event : Events::Event) : Nil
      case event
      when Events::AssistantTextDelta
        # Deltas are the only thing printed. Providers that do not stream
        # deliver one delta per block, so nothing is lost either way — and
        # AssistantText below must stay silent to avoid printing it twice.
        @io.print event.text
        @io.flush
      when Events::AssistantText
        @answer << event.text
      when Events::ToolStart
        @io.puts "\n🔧 Executing tool: \e[33m#{event.tool_name}\e[0m with args: #{event.args.to_json}"
      when Events::ToolFinished
        if event.is_error
          @io.puts "❌ Tool \e[31m#{event.tool_name}\e[0m failed: #{event.result}"
        else
          @io.puts "✅ Tool \e[32m#{event.tool_name}\e[0m finished."
        end
      when Events::TodosUpdated
        if event.items.empty?
          @io.puts "\n📋 Todos cleared."
        else
          @io.puts "\n📋 Todos:"
          event.items.each do |item|
            case item.status
            when .completed?   then @io.puts "   \e[2m☑ #{item.content}\e[0m"
            when .in_progress? then @io.puts "   \e[1m▶ #{item.content}\e[0m"
            else                    @io.puts "   ☐ #{item.content}"
            end
          end
        end
      when Events::HookFired
        if event.blocked?
          @io.puts "🪝 #{event.hook_event.to_key} \e[31mblocked\e[0m: #{event.command}"
        else
          @io.puts "🪝 #{event.hook_event.to_key}: #{event.command}"
        end
      when Events::PlanPresented
        @io.puts "\n📋 Plan\n"
        @io.puts event.plan
      when Events::ModeChanged
        @io.puts "\n🧭 Switched to #{event.mode.to_s.downcase} mode."
      when Events::HistoryCompacted
        @io.puts "\n🗜️  Context compacted (#{event.strategy}): ~#{event.before_tokens} → ~#{event.after_tokens} tokens"
      when Events::TurnError
        @failed = true
        @io.puts "\n❌ Error: #{event.error}"
      end
    end

    def finish(usage : LLM::Usage) : Nil
      # Only mentioned when there is something to mention — three of the four
      # providers never cache anything.
      cached = usage.cached_tokens.zero? ? "" : " (#{usage.cached_tokens} cached)"

      @io.puts "\n--------------------------------------------------"
      @io.puts "📊 Usage: #{usage.prompt_tokens} prompt#{cached} + #{usage.completion_tokens} completion = #{usage.total_tokens} total tokens"
    end
  end

  # One JSON object per line on stdout and nothing else, so `smith run --json
  # ... | jq` works without any pre-filtering. Decoration goes to stderr.
  class JsonRenderer < Renderer
    def initialize(@io : IO = STDOUT, @err : IO = STDERR)
    end

    def prompt_io : IO
      @err
    end

    def banner(provider : String, model : String, skills : Array(String)) : Nil
      @err.puts "⚒️  Running Smith Headless [Provider: #{provider} | Model: #{model}]"
      @err.puts "   Loaded Skills: #{skills.join(", ")}" unless skills.empty?
    end

    def handle(event : Events::Event) : Nil
      case event
      when Events::AssistantTextDelta
        emit do |json|
          json.field "type", "assistant_text_delta"
          json.field "text", event.text
        end
      when Events::AssistantText
        @answer << event.text
        emit do |json|
          json.field "type", "assistant_text"
          json.field "text", event.text
        end
      when Events::ToolStart
        emit do |json|
          json.field "type", "tool_start"
          json.field "id", event.tool_call_id
          json.field "tool", event.tool_name
          json.field "args", event.args
        end
      when Events::ToolFinished
        emit do |json|
          json.field "type", "tool_finished"
          json.field "id", event.tool_call_id
          json.field "tool", event.tool_name
          json.field "is_error", event.is_error
          json.field "result", event.result
        end
      when Events::TodosUpdated
        emit do |json|
          json.field "type", "todos_updated"
          json.field "todos" do
            json.array do
              event.items.each do |item|
                json.object do
                  json.field "content", item.content
                  json.field "status", item.status
                end
              end
            end
          end
        end
      when Events::HookFired
        emit do |json|
          json.field "type", "hook_fired"
          json.field "event", event.hook_event.to_key
          json.field "command", event.command
          json.field "blocked", event.blocked?
        end
      when Events::PlanPresented
        emit do |json|
          json.field "type", "plan_presented"
          json.field "plan", event.plan
        end
      when Events::ModeChanged
        emit do |json|
          json.field "type", "mode_changed"
          json.field "mode", event.mode.to_s.downcase
        end
      when Events::HistoryCompacted
        emit do |json|
          json.field "type", "history_compacted"
          json.field "strategy", event.strategy
          json.field "before_tokens", event.before_tokens
          json.field "after_tokens", event.after_tokens
        end
      when Events::TurnError
        @failed = true
        emit do |json|
          json.field "type", "turn_error"
          json.field "error", event.error
        end
      end
    end

    # Always the last line, carrying the answer reassembled from every text
    # block, so a consumer can just take the final object.
    def finish(usage : LLM::Usage) : Nil
      emit do |json|
        json.field "type", "result"
        json.field "text", answer
        json.field "usage" do
          json.object do
            json.field "prompt_tokens", usage.prompt_tokens
            json.field "completion_tokens", usage.completion_tokens
            json.field "total_tokens", usage.total_tokens
            json.field "cache_creation_tokens", usage.cache_creation_tokens
            json.field "cache_read_tokens", usage.cache_read_tokens
          end
        end
      end
    end

    private def emit(&)
      line = JSON.build do |json|
        json.object do
          yield json
        end
      end

      @io.puts(line)
      @io.flush
    end
  end
end
