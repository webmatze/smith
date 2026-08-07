require "process"
require "json"
require "./tool"
require "./bash_jobs"

module Smith::Tools
  class Bash < Tool
    include MutatingTool

    MAX_OUTPUT_BYTES = 256 * 1024 # 256 KiB limit
    DEFAULT_TIMEOUT  = 120

    getter jobs : BashJobs
    getter timeout : Int32

    def initialize(
      jobs : BashJobs? = nil,
      @timeout : Int32 = DEFAULT_TIMEOUT,
      @max_output_bytes : Int32 = MAX_OUTPUT_BYTES,
    )
      @jobs = jobs || BashJobs.new(File.join(Dir.tempdir, "smith-bash-#{Process.pid}"))
    end

    def name : String
      "bash"
    end

    def description : String
      "Execute a shell command in the local environment and return stdout/stderr. " \
      "Set background: true for anything long-lived — a dev server, a log tail — and read it with bash_output. " \
      "A foreground command that outruns its #{@timeout}s timeout is moved to the background rather than killed."
    end

    def parameters : JSON::Any
      JSON.parse(%({
        "type": "object",
        "properties": {
          "command": {
            "type": "string",
            "description": "The bash command line string to execute."
          },
          "background": {
            "type": "boolean",
            "description": "Return immediately and keep the command running. Read its output with bash_output."
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

      background = args["background"]?.try(&.as_bool?) || false

      job = begin
        @jobs.start(command)
      rescue ex : Exception
        return "Execution Error: #{ex.message}"
      end

      if job.nil?
        return "Error: too many background jobs (limit #{@jobs.max_jobs}). Kill one with bash_kill first."
      end

      return "Started in background with id #{job.id}. Use bash_output to read its output." if background

      # Output has been going to the job's log since the first byte, so this
      # deadline decides only how long to keep waiting — nothing is re-attached
      # and nothing is discarded.
      return moved_to_background(job) unless job.wait(@timeout.seconds)

      finished(job)
    end

    private def finished(job : BashJob) : String
      output = job.read_new
      code = job.exit_code || 0

      text = String.build do |str|
        str.puts output unless output.empty?
        str.puts "\nCommand failed with exit code #{code}" unless code.zero?
      end

      # The job is done and its output has been handed over, so neither the
      # entry nor the log is of any further use.
      @jobs.discard(job)

      truncate_output(text.empty? ? "(Command completed with no output)" : text)
    end

    # Killing at the timeout throws away whatever the command already produced,
    # which for a build is regularly the wrong call.
    private def moved_to_background(job : BashJob) : String
      output = job.read_new

      String.build do |str|
        str.puts "Command still running after #{@timeout}s; moved to background as #{job.id}."
        str.puts "Use bash_output with id #{job.id} to read the rest, or bash_kill to stop it."
        unless output.empty?
          str.puts "\nOutput so far:"
          str.puts truncate_output(output)
        end
      end
    end

    private def truncate_output(str : String) : String
      if str.bytesize > @max_output_bytes
        truncated = str.byte_slice(0, @max_output_bytes)
        "#{truncated}\n\n... [Output truncated to #{@max_output_bytes // 1024} KiB cap]"
      else
        str
      end
    end
  end
end
