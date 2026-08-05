require "json"
require "./tool"

module Smith::Tools
  class Grep < Tool
    include ParallelTool

    MAX_MATCHES = 200

    def name : String
      "grep"
    end

    def description : String
      "Search for a pattern or string across files in the workspace."
    end

    def parameters : JSON::Any
      JSON.parse(%({
        "type": "object",
        "properties": {
          "query": {
            "type": "string",
            "description": "Regex or string search query."
          },
          "path": {
            "type": "string",
            "description": "Optional search directory path (defaults to current directory)."
          }
        },
        "required": ["query"]
      }))
    end

    def run(args : JSON::Any) : String
      query = args["query"]?.try(&.as_s?)
      return "Error: 'query' argument is required." if query.nil?

      search_path = args["path"]?.try(&.as_s?) || "."
      unless Dir.exists?(search_path) || File.exists?(search_path)
        return "Error: Path '#{search_path}' does not exist."
      end

      regex = begin
        Regex.new(query)
      rescue
        Regex.new(Regex.escape(query))
      end

      matches = Array(String).new
      total_count = 0

      begin
        files = File.file?(search_path) ? [search_path] : Dir.glob("#{search_path}/**/*")
        files.each do |file_path|
          next unless File.file?(file_path)
          next if file_path.includes?("/.git/") || file_path.includes?("/bin/") || file_path.includes?("/lib/")

          begin
            line_num = 0
            File.each_line(file_path, chomp: true) do |line|
              line_num += 1
              if regex.match(line)
                total_count += 1
                if matches.size < MAX_MATCHES
                  matches << "#{file_path}:#{line_num}: #{line}"
                end
              end
            end
          rescue
            # Skip unreadable or binary files
          end
        end

        if matches.empty?
          "No matches found for query: '#{query}'"
        else
          result = matches.join("\n")
          if total_count > MAX_MATCHES
            result += "\n\n... [#{total_count - MAX_MATCHES} more matches omitted]"
          end
          result
        end
      rescue ex : Exception
        "Error running grep: #{ex.message}"
      end
    end
  end
end
