require "process"
require "json"
require "./tool"

module Smith::Tools
  class Bash < Tool
    MAX_OUTPUT_BYTES = 256 * 1024 # 256 KiB limit

    def name : String
      "bash"
    end

    def description : String
      "Execute a shell command in the local environment and return stdout/stderr."
    end

    def parameters : JSON::Any
      JSON.parse(%({
        "type": "object",
        "properties": {
          "command": {
            "type": "string",
            "description": "The bash command line string to execute."
          }
        },
        "required": ["command"]
      }))
    end

    def run(args : JSON::Any) : String
      command = args["command"]?.try(&.as_s?)
      if command.nil? || command.strip.empty?
        return "Error: 'command' argument is required and cannot be empty."
      end

      stdout_io = IO::Memory.new
      stderr_io = IO::Memory.new

      begin
        process = Process.new(
          "/bin/bash",
          ["-c", command],
          output: stdout_io,
          error: stderr_io
        )

        status = process.wait

        stdout_str = stdout_io.to_s
        stderr_str = stderr_io.to_s

        output = String.build do |str|
          unless stdout_str.empty?
            str.puts stdout_str
          end
          unless stderr_str.empty?
            str.puts "STDERR:\n#{stderr_str}"
          end
          if status.exit_code != 0
            str.puts "\nCommand failed with exit code #{status.exit_code}"
          end
        end

        output = output.empty? ? "(Command completed with no output)" : output
        truncate_output(output)
      rescue ex : Exception
        "Execution Error: #{ex.message}"
      end
    end

    private def truncate_output(str : String) : String
      if str.bytesize > MAX_OUTPUT_BYTES
        truncated = str.byte_slice(0, MAX_OUTPUT_BYTES)
        "#{truncated}\n\n... [Output truncated to 256 KiB cap]"
      else
        str
      end
    end
  end
end
