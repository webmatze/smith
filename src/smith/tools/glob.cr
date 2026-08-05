require "json"
require "./tool"

module Smith::Tools
  class Glob < Tool
    include ParallelTool

    MAX_FILES = 200

    def name : String
      "glob"
    end

    def description : String
      "Find files matching a glob pattern (e.g. '**/*.cr', 'src/**/*.rb')."
    end

    def parameters : JSON::Any
      JSON.parse(%({
        "type": "object",
        "properties": {
          "pattern": {
            "type": "string",
            "description": "Glob pattern to match files against."
          }
        },
        "required": ["pattern"]
      }))
    end

    def run(args : JSON::Any) : String
      pattern = args["pattern"]?.try(&.as_s?)
      return "Error: 'pattern' argument is required." if pattern.nil?

      begin
        matches = Dir.glob(pattern)
        if matches.empty?
          "No files matched pattern: '#{pattern}'"
        else
          total = matches.size
          limited = matches.first(MAX_FILES)
          out_str = limited.join("\n")
          if total > MAX_FILES
            out_str += "\n\n... [#{total - MAX_FILES} more files omitted]"
          end
          out_str
        end
      rescue ex : Exception
        "Error running glob pattern '#{pattern}': #{ex.message}"
      end
    end
  end
end
