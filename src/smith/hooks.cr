require "json"
require "process"

# User-configured subprocesses that observe and steer the agent loop.
#
# This is the point of the "policy-free core": everything smith itself refuses
# to decide — which formatter to run, which secrets may not be written, whether
# the tests have to pass before a turn ends — is a hook rather than a patch.
#
# A hook that misbehaves must never take smith down. Every failure mode short
# of an explicit block (exit 2, or a JSON deny) is a warning on stderr and the
# run carries on.
module Smith::Hooks
  DEFAULT_TIMEOUT = 60

  enum Event
    SessionStart
    UserPromptSubmit
    PreToolUse
    PostToolUse
    Stop

    # The spelling used in config.toml and in the `hook_event_name` field.
    def to_key : String
      to_s.underscore
    end

    def self.from_key(key : String) : Event?
      parse?(key)
    end
  end

  struct Definition
    getter event : Event
    getter matcher : Regex?
    getter command : String
    getter timeout : Int32
    getter? once : Bool

    def initialize(
      @event : Event,
      @command : String,
      @matcher : Regex? = nil,
      @timeout : Int32 = DEFAULT_TIMEOUT,
      @once : Bool = false,
    )
    end

    # Without a matcher a hook applies to everything. `subject` is the tool
    # name for the tool events and empty elsewhere.
    def matches?(subject : String) : Bool
      m = @matcher
      return true if m.nil?

      !!m.match(subject)
    end
  end

  struct Outcome
    getter? blocked : Bool
    getter reason : String?
    getter updated_input : JSON::Any?
    getter additional_context : String?
    getter? ask : Bool

    def initialize(
      @blocked : Bool = false,
      @reason : String? = nil,
      @updated_input : JSON::Any? = nil,
      @additional_context : String? = nil,
      @ask : Bool = false,
    )
    end
  end

  class Runner
    BLOCK_EXIT_CODE = 2

    # Fired for every hook that actually ran, so the renderers can show it.
    property on_fire : Proc(Event, String, Bool, Nil)?

    def initialize(
      @definitions : Array(Definition) = Array(Definition).new,
      @session_id : String = "",
      @project_dir : String = Dir.current,
      @warn_io : IO = STDERR,
    )
      @fired = Set(Int32).new
    end

    def empty? : Bool
      @definitions.empty?
    end

    def any?(event : Event) : Bool
      @definitions.any? { |d| d.event == event }
    end

    # Runs every matching hook in order. The first one to block wins and the
    # rest are skipped, but the context gathered before it is kept.
    def run(event : Event, payload : JSON::Any = JSON.parse("{}")) : Outcome
      subject = payload["tool_name"]?.try(&.as_s?) || ""
      context = String::Builder.new
      updated_input = nil
      ask = false

      @definitions.each_with_index do |definition, index|
        next unless definition.event == event
        next unless definition.matches?(subject)
        next if definition.once? && @fired.includes?(index)

        @fired << index
        result = execute(definition, event, payload)
        next if result.nil?

        context << result.additional_context if result.additional_context
        updated_input = result.updated_input if result.updated_input
        ask ||= result.ask?

        if result.blocked?
          return Outcome.new(
            blocked: true,
            reason: result.reason,
            additional_context: collected(context),
            updated_input: updated_input
          )
        end
      end

      Outcome.new(
        additional_context: collected(context),
        updated_input: updated_input,
        ask: ask
      )
    end

    private def collected(context : String::Builder) : String?
      text = context.to_s.strip
      text.empty? ? nil : text
    end

    # Returns nil when the hook could not be run at all — indistinguishable
    # from "had nothing to say", and deliberately never a block.
    private def execute(definition : Definition, event : Event, payload : JSON::Any) : Outcome?
      stdout_io = IO::Memory.new
      stderr_io = IO::Memory.new

      process = begin
        Process.new(
          "/bin/bash",
          ["-c", definition.command],
          input: :pipe,
          output: stdout_io,
          error: stderr_io,
          env: {
            "SMITH_PROJECT_DIR" => @project_dir,
            "SMITH_SESSION_ID"  => @session_id,
            "SMITH_HOOK_EVENT"  => event.to_key,
          }
        )
      rescue ex : Exception
        warn(definition, "could not be started: #{ex.message}")
        return nil
      end

      feed(process, envelope(event, payload))

      status = wait_with_timeout(process, definition.timeout)
      if status.nil?
        warn(definition, "timed out after #{definition.timeout}s")
        return nil
      end

      result = interpret(definition, status, stdout_io.to_s, stderr_io.to_s)

      # Reported here rather than in #run, so a hook that ran fine and simply
      # had nothing to say is still visible.
      @on_fire.try &.call(event, definition.command, !!result.try(&.blocked?))

      result
    end

    # Hooks are not obliged to read their stdin — `exit 2` does not, and
    # neither does a formatter. Handing Process an IO would leave that case to
    # its internal copy fiber, where the resulting EPIPE escapes unhandled; and
    # a payload larger than the pipe buffer (a write_file carrying a big file)
    # would block that fiber forever, taking Process#wait with it.
    #
    # So the pipe is driven here instead: in our own fiber, so a hook that
    # never drains it cannot stall the wait, and closed either way so the hook
    # sees EOF.
    private def feed(process : Process, payload : String) : Nil
      spawn do
        begin
          process.input.print(payload)
        rescue IO::Error
          # The hook exited without reading. Entirely legitimate.
        ensure
          begin
            process.input.close
          rescue IO::Error
          end
        end
      end
    end

    # Process#wait has no timeout of its own, so the wait happens in a fiber
    # and the process is killed if the deadline passes first.
    private def wait_with_timeout(process : Process, timeout : Int32) : Process::Status?
      channel = Channel(Process::Status).new(1)
      spawn { channel.send(process.wait) }

      select
      when status = channel.receive
        status
      when timeout(timeout.seconds)
        process.signal(Signal::KILL) rescue nil
        # Reap it so the killed process does not linger as a zombie.
        spawn { channel.receive }
        nil
      end
    end

    private def interpret(definition : Definition, status : Process::Status, stdout : String, stderr : String) : Outcome?
      case status.exit_code
      when 0
        interpret_success(stdout)
      when BLOCK_EXIT_CODE
        reason = stderr.strip
        Outcome.new(blocked: true, reason: reason.empty? ? "Blocked by hook: #{definition.command}" : reason)
      else
        # A hook that is simply broken must not become a policy decision.
        warn(definition, "exited with exit code #{status.exit_code}#{stderr.strip.empty? ? "" : ": #{stderr.strip}"}")
        nil
      end
    end

    private def interpret_success(stdout : String) : Outcome?
      text = stdout.strip
      return nil if text.empty?

      json = begin
        parsed = JSON.parse(text)
        parsed.as_h? ? parsed : nil
      rescue JSON::ParseException
        nil
      end

      # Not JSON, or JSON that is not an object: plain output, handed to the
      # model as context. A hook that echoes a JSON *object* is therefore
      # always read as a control response — documented, and the reason
      # additional_context exists as an explicit field.
      return Outcome.new(additional_context: text) if json.nil?

      decision = json["decision"]?.try(&.as_s?)

      Outcome.new(
        blocked: decision == "deny",
        ask: decision == "ask",
        reason: json["reason"]?.try(&.as_s?),
        updated_input: json["updated_input"]?,
        additional_context: json["additional_context"]?.try(&.as_s?)
      )
    end

    private def envelope(event : Event, payload : JSON::Any) : String
      JSON.build do |json|
        json.object do
          json.field "hook_event_name", event.to_key
          json.field "session_id", @session_id
          json.field "cwd", @project_dir

          payload.as_h.each do |key, value|
            json.field key, value
          end
        end
      end
    end

    private def warn(definition : Definition, message : String) : Nil
      @warn_io.puts "⚠️  Hook '#{definition.command}' #{message} — continuing."
      @warn_io.flush
    end
  end
end
