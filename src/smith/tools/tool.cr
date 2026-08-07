require "json"
require "../llm/types"

module Smith::Tools
  # Marker module for tools that are safe for concurrent execution (e.g. read_file, grep, glob)
  module ParallelTool
  end

  # Marker module for tools that change the world outside smith — shell
  # commands and file writes. These pass through the approval gate in
  # Registry#execute_single_call; unmarked tools bypass it.
  module MutatingTool
  end

  abstract class Tool
    abstract def name : String
    abstract def description : String
    abstract def parameters : JSON::Any
    abstract def run(args : JSON::Any) : String

    def spec : Smith::LLM::ToolSpec
      Smith::LLM::ToolSpec.new(
        name: name,
        description: description,
        parameters: parameters
      )
    end

    def parallel? : Bool
      is_a?(ParallelTool)
    end

    def mutating? : Bool
      is_a?(MutatingTool)
    end
  end
end
