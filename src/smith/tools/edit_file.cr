require "json"
require "./tool"

module Smith::Tools
  class EditFile < Tool
    include MutatingTool

    def name : String
      "edit_file"
    end

    def description : String
      "Replace target substring with replacement content in an existing file."
    end

    def parameters : JSON::Any
      JSON.parse(%({
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "File path to edit."
          },
          "target": {
            "type": "string",
            "description": "Exact text substring to replace."
          },
          "replacement": {
            "type": "string",
            "description": "New replacement string."
          }
        },
        "required": ["path", "target", "replacement"]
      }))
    end

    def run(args : JSON::Any) : String
      path = args["path"]?.try(&.as_s?)
      target = args["target"]?.try(&.as_s?)
      replacement = args["replacement"]?.try(&.as_s?)

      return "Error: 'path' argument is required." if path.nil?
      return "Error: 'target' argument is required." if target.nil?
      return "Error: 'replacement' argument is required." if replacement.nil?

      unless File.exists?(path)
        return "Error: File '#{path}' does not exist."
      end

      begin
        content = File.read(path)
        occurrences = content.scan(target).size

        if occurrences == 0
          return "Error: Target string not found in '#{path}'."
        elsif occurrences > 1
          return "Error: Target string found #{occurrences} times in '#{path}'. Target must match uniquely."
        end

        new_content = content.gsub(target, replacement)
        File.write(path, new_content)
        "Successfully updated '#{path}'."
      rescue ex : Exception
        "Error editing file '#{path}': #{ex.message}"
      end
    end
  end
end
