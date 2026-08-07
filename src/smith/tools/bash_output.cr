require "json"
require "./tool"
require "./bash_jobs"

module Smith::Tools
  # Reads what a background job has produced since the last look.
  #
  # Not mutating — it only reads — but not parallel-safe either: it moves a
  # cursor shared with every other reader of the same job.
  class BashOutput < Tool
    def initialize(@jobs : BashJobs)
    end

    def name : String
      "bash_output"
    end

    def description : String
      "Read the output a background command has produced since the last call, along with its status. " \
      "Only new output is returned, so following a long-running log does not resend it every time."
    end

    def parameters : JSON::Any
      JSON.parse(%({
        "type": "object",
        "properties": {
          "id": {
            "type": "string",
            "description": "The job id, e.g. 'bash-1'."
          },
          "filter": {
            "type": "string",
            "description": "Optional regular expression; only matching lines are returned."
          }
        },
        "required": ["id"]
      }))
    end

    def run(args : JSON::Any) : String
      id = args["id"]?.try(&.as_s?)
      return "Error: 'id' argument is required." if id.nil?

      job = @jobs[id]
      if job.nil?
        known = @jobs.jobs.map(&.id)
        return "Error: no background job '#{id}'. " +
          (known.empty? ? "None are running." : "Known: #{known.join(", ")}.")
      end

      filter = nil
      if pattern = args["filter"]?.try(&.as_s?)
        filter = begin
          Regex.new(pattern)
        rescue ArgumentError
          return "Error: invalid filter #{pattern.inspect}."
        end
      end

      output = job.read_new(filter)

      String.build do |str|
        str.puts "[#{job.id}] #{job.status} — running for #{job.runtime.total_seconds.round}s"
        str.puts(output.empty? ? "(no new output)" : output)
      end
    end
  end

  # Stops a background job. Mutating: it terminates something that was running.
  class BashKill < Tool
    include MutatingTool

    def initialize(@jobs : BashJobs)
    end

    def name : String
      "bash_kill"
    end

    def description : String
      "Stop a background command started with bash."
    end

    def parameters : JSON::Any
      JSON.parse(%({
        "type": "object",
        "properties": {
          "id": {
            "type": "string",
            "description": "The job id, e.g. 'bash-1'."
          }
        },
        "required": ["id"]
      }))
    end

    def run(args : JSON::Any) : String
      id = args["id"]?.try(&.as_s?)
      return "Error: 'id' argument is required." if id.nil?

      job = @jobs[id]
      return "Error: no background job '#{id}'." if job.nil?
      return "Job #{id} had already finished (#{job.status})." unless job.running?

      job.kill
      "Job #{id} killed."
    end
  end
end
