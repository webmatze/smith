require "json"
require "file_utils"
require "./tool"

module Smith::Tools
  class WriteFile < Tool
    def name : String
      "write_file"
    end

    def description : String
      "Write content to a file. Creates parent directories if missing."
    end

    def parameters : JSON::Any
      JSON.parse(%({
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "Absolute or relative file path to write."
          },
          "content": {
            "type": "string",
            "description": "Full file content string to write."
          }
        },
        "required": ["path", "content"]
      }))
    end

    def run(args : JSON::Any) : String
      path = args["path"]?.try(&.as_s?)
      content = args["content"]?.try(&.as_s?)

      return "Error: 'path' argument is required." if path.nil?
      return "Error: 'content' argument is required." if content.nil?

      begin
        dir = File.dirname(path)
        FileUtils.mkdir_p(dir) unless Dir.exists?(dir)

        File.write(path, content)
        "Successfully wrote #{content.bytesize} bytes to '#{path}'."
      rescue ex : Exception
        "Error writing to file '#{path}': #{ex.message}"
      end
    end
  end
end
