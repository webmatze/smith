require "file_utils"
require "../sandbox"
require "process"

module Smith::Tools
  # A shell command that outlives the tool call that started it.
  #
  # Output goes to a file from the very first byte, never to a buffer. That is
  # what makes auto-backgrounding seamless: a command that outruns its timeout
  # is simply not waited on any longer — nothing is re-attached, re-run, or
  # thrown away.
  class BashJob
    enum State
      Running
      Exited
      Killed
    end

    getter id : String
    getter command : String
    getter log_path : String
    getter started_at : Time
    getter exit_code : Int32?

    # Frozen when the job ends, so a finished job does not appear to keep
    # running for longer and longer.
    @ended_at : Time?

    @cursor : Int64 = 0
    @state : State = State::Running
    @killed = false

    def initialize(@id : String, @command : String, @log_path : String, @process : Process)
      @started_at = Time.local
      @done = Channel(Nil).new

      spawn do
        status = @process.wait
        @exit_code = status.exit_code unless @killed
        @state = @killed ? State::Killed : State::Exited
        @ended_at = Time.local
        # Closed rather than sent to: a single value releases a single waiter,
        # and there are regularly two — the tool call waiting out its timeout
        # and the fiber that fires on_exit. Closing wakes both.
        @done.close
      end
    end

    def running? : Bool
      @state.running?
    end

    def status : String
      case @state
      in State::Running then "running"
      in State::Killed  then "killed"
      in State::Exited  then "exited(#{@exit_code})"
      end
    end

    def runtime : Time::Span
      (@ended_at || Time.local) - @started_at
    end

    # Only what has arrived since the last call. A `tail -f` job would
    # otherwise push its whole log into the context on every read.
    def read_new(filter : Regex? = nil) : String
      return "" unless File.exists?(@log_path)

      chunk = File.open(@log_path) do |file|
        size = file.size
        return "" if size <= @cursor

        file.seek(@cursor)
        text = file.gets_to_end
        @cursor = size
        text
      end

      return chunk if filter.nil?

      chunk.lines.select { |line| filter.matches?(line) }.join("\n")
    end

    # Blocks until the job ends, however long that takes.
    #
    # Deliberately not `wait(Time::Span::MAX)`, which reads like the same
    # thing: the event loop arms a timer at `now + span`, and that overflows.
    # A deadline that cannot be represented is not a deadline — so this arms
    # no timer at all.
    def wait : Nil
      return unless running?

      @done.receive?
    end

    # True when the job finished within the span.
    def wait(span : Time::Span) : Bool
      return true unless running?

      select
      when @done.receive?
        true
      when timeout(span)
        false
      end
    end

    def kill(grace : Time::Span = 5.seconds) : Nil
      return unless running?

      @killed = true
      begin
        @process.signal(Signal::TERM)
      rescue
        # Already gone between the check and the signal.
      end

      return if wait(grace)

      begin
        @process.signal(Signal::KILL)
      rescue
      end
      wait(1.second)
    end
  end

  class BashJobs
    getter dir : String
    getter max_jobs : Int32

    # Wired by the CLI to the renderers. The tools have no access to the event
    # bus, and giving them one would put event knowledge into the core.
    property on_start : Proc(BashJob, Nil)?
    property on_exit : Proc(BashJob, Nil)?

    def initialize(
      @dir : String,
      @max_jobs : Int32 = 10,
      # Off by default for the same reason Registry defaults to an
      # AutoApprover: this stays usable as a plain library component, and the
      # CLI attaches the configured one.
      @sandbox : Smith::Sandbox::Strategy = Smith::Sandbox::Off.new,
    )
      @jobs = Hash(String, BashJob).new
      @counter = 0
    end

    def jobs : Array(BashJob)
      @jobs.values
    end

    def running : Array(BashJob)
      jobs.select(&.running?)
    end

    def [](id : String) : BashJob?
      @jobs[id]?
    end

    # nil when the limit is reached. Only jobs still running count, so a
    # finished one does not hold a slot forever.
    def start(command : String) : BashJob?
      return nil if running.size >= @max_jobs

      FileUtils.mkdir_p(@dir, mode: 0o700) unless Dir.exists?(@dir)

      @counter += 1
      id = "bash-#{@counter}"
      log_path = File.join(@dir, "#{id}.log")

      log = File.open(log_path, "w")

      # The single place a shell process is created, so it is also the single
      # place confinement can be applied — background jobs included, without a
      # second path that could forget it.
      program, arguments = @sandbox.wrap(command)
      process = Process.new(program, arguments, output: log, error: log)

      job = BashJob.new(id, command, log_path, process)
      @jobs[id] = job

      @on_start.try &.call(job)
      if notify = @on_exit
        spawn do
          job.wait
          notify.call(job)
        end
      end

      job
    end

    # Drops a finished job and its log. The output has already been handed to
    # the model, so keeping either would only accumulate.
    def discard(job : BashJob) : Nil
      @jobs.delete(job.id)
      File.delete(job.log_path) if File.exists?(job.log_path)
    end

    # A dev server left running as an orphan, holding its port, is a bug and
    # not a feature — so nothing survives the session that started it.
    def shutdown_all(grace : Time::Span = 5.seconds) : Nil
      running.each(&.kill(grace: grace))
    end
  end
end
