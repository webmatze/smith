require "json"
require "./tool"
require "./approval"
require "./todo_write"
require "../llm/types"

module Smith::Tools
  struct CallRequest
    getter id : String
    getter name : String
    getter args : JSON::Any

    def initialize(@id : String, @name : String, @args : JSON::Any)
    end
  end

  struct CallResult
    getter id : String
    getter content : String
    getter is_error : Bool

    def initialize(@id : String, @content : String, @is_error : Bool = false)
    end

    def to_content_block : Smith::LLM::ContentBlock
      Smith::LLM::ContentBlock.tool_result(@id, @content, @is_error)
    end
  end

  class Registry
    @tools = Hash(String, Tool).new

    # Defaults to allowing everything so Registry stays usable as a plain
    # library component. Callers that have a user in front of them — the CLI —
    # must attach a real approver.
    property approver : Approver

    def initialize(@approver : Approver = AutoApprover.new)
    end

    def register(tool : Tool)
      @tools[tool.name] = tool
    end

    def get(name : String) : Tool?
      @tools[name]?
    end

    def specs : Array(Smith::LLM::ToolSpec)
      @tools.values.map(&.spec)
    end

    def execute_call(name : String, args : JSON::Any) : String
      tool = get(name)
      if tool.nil?
        return "Error: Unknown tool '#{name}'"
      end

      tool.run(args)
    end

    # Executes a batch of tool requests. Runs adjacent parallel-safe tools concurrently via Fibers.
    def execute_calls(calls : Array(CallRequest)) : Array(Smith::LLM::ContentBlock)
      results = Array(Smith::LLM::ContentBlock).new

      # Group contiguous calls into parallel vs serial execution chunks
      chunks = partition_calls(calls)

      chunks.each do |chunk|
        if chunk.first_parallel?
          # Concurrent fiber execution
          chunk_results = execute_parallel_chunk(chunk.calls)
          results.concat(chunk_results.map(&.to_content_block))
        else
          # Serial execution
          chunk.calls.each do |call|
            res = execute_single_call(call)
            results << res.to_content_block
          end
        end
      end

      results
    end

    private class CallChunk
      getter calls : Array(CallRequest)
      getter? first_parallel : Bool

      def initialize(@calls : Array(CallRequest), @first_parallel : Bool)
      end
    end

    private def partition_calls(calls : Array(CallRequest)) : Array(CallChunk)
      chunks = Array(CallChunk).new
      return chunks if calls.empty?

      current_calls = Array(CallRequest).new
      current_parallel = false

      calls.each do |call|
        tool = get(call.name)
        is_parallel = tool ? tool.parallel? : false

        if current_calls.empty?
          current_calls << call
          current_parallel = is_parallel
        elsif current_parallel == is_parallel && is_parallel
          current_calls << call
        else
          chunks << CallChunk.new(current_calls, current_parallel)
          current_calls = [call]
          current_parallel = is_parallel
        end
      end

      unless current_calls.empty?
        chunks << CallChunk.new(current_calls, current_parallel)
      end

      chunks
    end

    private def execute_parallel_chunk(calls : Array(CallRequest)) : Array(CallResult)
      channel = Channel(Tuple(Int32, CallResult)).new
      results = Array(CallResult?).new(calls.size, nil)

      calls.each_with_index do |call, index|
        spawn do
          res = execute_single_call(call)
          channel.send({index, res})
        end
      end

      calls.size.times do
        index, res = channel.receive
        results[index] = res
      end

      results.compact
    end

    private def execute_single_call(call : CallRequest) : CallResult
      tool = get(call.name)
      if tool.nil?
        return CallResult.new(call.id, "Error: Unknown tool '#{call.name}'", is_error: true)
      end

      # The single choke point for both the serial and the parallel path, so
      # no call can route around the gate. Read-only tools are never marked
      # mutating and pass straight through.
      if tool.mutating? && !@approver.approve?(tool, call)
        return CallResult.new(call.id, @approver.denial_message(tool), is_error: true)
      end

      begin
        output = tool.run(call.args)
        CallResult.new(call.id, output, is_error: false)
      rescue ex : Exception
        CallResult.new(call.id, "Tool execution failed: #{ex.message}", is_error: true)
      end
    end

    # Factory helper to register default standard toolset.
    #
    # `todos` defaults to a fresh list for the same reason `approver` defaults
    # to allowing everything: the Registry stays usable as a plain library
    # component. Callers that want to observe or persist the plan — the CLI —
    # pass their own list in.
    def self.default(approver : Approver = AutoApprover.new, todos : Smith::TodoList = Smith::TodoList.new) : Registry
      registry = Registry.new(approver)
      registry.register(Bash.new)
      registry.register(ReadFile.new)
      registry.register(WriteFile.new)
      registry.register(EditFile.new)
      registry.register(Grep.new)
      registry.register(Glob.new)
      registry.register(TodoWrite.new(todos))
      registry
    end
  end
end
