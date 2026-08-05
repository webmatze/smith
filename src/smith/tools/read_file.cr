require "json"
require "./tool"

module Smith::Tools
  class ReadFile < Tool
    include ParallelTool

    MAX_BYTES = 256 * 1024 # 256 KiB cap

    def name : String
      "read_file"
    end

    def description : String
      "Read content from a text file on disk, with optional line range."
    end

    def parameters : JSON::Any
      JSON.parse(%({
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "Absolute or relative file path to read."
          },
          "start_line": {
            "type": "integer",
            "description": "Optional 1-based start line number."
          },
          "end_line": {
            "type": "integer",
            "description": "Optional 1-based end line number."
          }
        },
        "required": ["path"]
      }))
    end

    def run(args : JSON::Any) : String
      path = args["path"]?.try(&.as_s?)
      return "Error: 'path' parameter is required." if path.nil?

      unless File.exists?(path)
        return "Error: File '#{path}' does not exist."
      end

      if File.directory?(path)
        return "Error: Path '#{path}' is a directory, not a file."
      end

      start_line = args["start_line"]?.try(&.as_i?)
      end_line = args["end_line"]?.try(&.as_i?)

      begin
        lines = File.read_lines(path)
        total_lines = lines.size

        s_idx = start_line ? {start_line - 1, 0}.max : 0
        e_idx = end_line ? {end_line - 1, total_lines - 1}.min : total_lines - 1

        if s_idx >= total_lines
          return "Error: start_line #{start_line} exceeds total file lines (#{total_lines})."
        end

        selected_lines = lines[s_idx..e_idx]? || Array(String).new

        result = String.build do |str|
          selected_lines.each_with_index(s_idx + 1) do |line, line_num|
            str.puts "#{line_num}: #{line}"
          end
        end

        if result.bytesize > MAX_BYTES
          truncated = result.byte_slice(0, MAX_BYTES)
          "#{truncated}\n\n... [Content truncated at 256 KiB limit]"
        else
          result
        end
      rescue ex : Exception
        "Error reading file '#{path}': #{ex.message}"
      end
    end
  end
end
