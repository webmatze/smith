require "json"
require "process"

# JSON-RPC 2.0 over a line-delimited byte stream — the framing half of MCP.
#
# Kept free of any knowledge about tools or servers so the transport can be
# swapped for an in-memory pair in the specs: the concurrency this file makes
# possible is the part worth testing, and testing it must not need a real
# process.
module Smith::MCP
  # The revision smith speaks. A server that answers with a different one is
  # not rejected — the spec asks clients to carry on if they can.
  PROTOCOL_VERSION = "2024-11-05"

  class Error < Exception
    # What smith may print in place of `message` where the server's own words
    # must not be repeated — a diagnostic meant to be pasted into a bug report.
    #
    # Defaults to the message, because smith composes most of these itself.
    # The ones that quote a server say so *on the value*, not by their class:
    # an error object can leave `Client` wrapped in a `ConnectionError`, and by
    # then the class no longer records whose words these are.
    getter safe_message : String

    def initialize(message : String? = nil, safe_message : String? = nil)
      @safe_message = safe_message || message || self.class.name
      super(message)
    end
  end

  # The server took too long. Deliberately *not* a ConnectionError: a slow
  # server is still a live one, and restarting it would throw away the work it
  # is presumably still doing.
  class TimeoutError < Error
  end

  # The pipe is gone — the process died, or never spoke the protocol. This is
  # the only failure a restart can plausibly fix.
  class ConnectionError < Error
  end

  # An error *result*: the call reached the server and the server said no.
  class RpcError < Error
    getter code : Int32

    # `message` is the server's own text in every case that comes off the
    # wire, so the default stand-in says only what smith knows: that there was
    # an error, and which code carried it. The reader fiber composes a couple
    # of these itself and passes its own `safe_message`, because there is then
    # nothing being held back.
    def initialize(@code : Int32, message : String, safe_message : String? = nil)
      super(message, safe_message || "the server answered the MCP protocol with an error (code #{@code})")
    end
  end

  # One decoded JSON-RPC message. Only what smith actually reads is kept:
  # requests from the server (sampling, roots) are out of scope for stage 1 and
  # are dropped by the reader rather than modelled here.
  struct Message
    getter id : Int64?
    getter method : String?
    getter result : JSON::Any?
    getter error : RpcError?

    def initialize(@id : Int64?, @method : String?, @result : JSON::Any?, @error : RpcError?)
    end

    # nil rather than raising: a server that writes a stray log line to stdout
    # must not take the connection down with it.
    def self.parse(line : String) : Message?
      json = begin
        JSON.parse(line)
      rescue JSON::ParseException
        return nil
      end

      object = json.as_h?
      return nil if object.nil?

      Message.new(
        id: decode_id(object["id"]?),
        method: object["method"]?.try(&.as_s?),
        result: object["result"]?,
        error: decode_error(object["error"]?)
      )
    end

    # The spec allows string ids. smith only ever sends numbers, but a server
    # is free to echo them back as strings and several do.
    private def self.decode_id(value : JSON::Any?) : Int64?
      return nil if value.nil?
      value.as_i64? || value.as_s?.try(&.to_i64?)
    end

    # The one place a server's text becomes an exception. `safe_message` is
    # deliberately not passed: the default is the guarded one, so text arriving
    # from the wire is unrepeatable unless somebody says otherwise, rather than
    # repeatable unless somebody remembers to guard it. A fourth producer of
    # server-authored text cannot appear without coming through here.
    private def self.decode_error(value : JSON::Any?) : RpcError?
      fields = value.try(&.as_h?)
      return nil if fields.nil?

      RpcError.new(
        code: fields["code"]?.try(&.as_i?) || 0,
        message: fields["message"]?.try(&.as_s?) || "unknown error"
      )
    end

    # A response carries an id and no method; a notification is the other way
    # round. Only responses are dispatched to a waiting caller.
    def response? : Bool
      !@id.nil? && @method.nil?
    end
  end

  module Protocol
    def self.request(id : Int64, method : String, params : JSON::Any? = nil) : String
      JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field "id", id
          json.field "method", method
          json.field "params", params unless params.nil?
        end
      end
    end

    def self.notification(method : String, params : JSON::Any? = nil) : String
      JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field "method", method
          json.field "params", params unless params.nil?
        end
      end
    end
  end

  abstract class Transport
    # One complete message. Framing is line-based, so neither side may embed a
    # raw newline — JSON escapes them, which is why this works at all.
    abstract def send(line : String) : Nil

    # nil at end of stream. Blocking; called only from the reader fiber.
    abstract def receive : String?

    abstract def close : Nil

    # Why the stream died, when the transport knows more than "EOF". stdio has
    # nothing to add; an HTTP transport can say which status or which network
    # error it was.
    #
    # It has two readers and both of them publish it: `Client#abandon_pending`
    # hands it to every caller it gives up on, from where it becomes a tool
    # result — the model's context, `transcript.jsonl`, every export of the
    # session — and a transport may raise it again at the next write. There is
    # no filter between here and any of that, so a transport composing one owes
    # it: anything taken from `mcp.json` arrives cut back, a url to scheme,
    # host and port. `HttpTransport#die!` is the worked example.
    def failure_hint : String?
      nil
    end

    # What an HTTP server put in the body of a failing answer. Kept apart from
    # `failure_hint` for the same reason a subprocess's stderr is kept apart
    # from the message smith composes: it is *the server's* text, it can hold
    # anything the server was sent — a gateway echoing an Authorization header
    # back is not hypothetical — and only the caller knows whether repeating
    # it is the answer being looked for or a secret being published.
    def failure_body : String?
      nil
    end

    # Wait, briefly, for whatever the server wrote to stderr to have been read.
    # Only stdio has a stderr to drain, and only a transport knows when its
    # own draining is finished — so the caller that is about to quote
    # `stderr_tail` asks here rather than guessing with a sleep.
    def await_stderr : Nil
    end

    # A subprocess's own stderr, kept so a failed handshake can say what the
    # process actually complained about. Only stdio has one.
    def stderr_tail : Array(String)
      Array(String).new
    end
  end

  # A child process speaking JSON-RPC over its stdin/stdout.
  #
  # stderr is drained by its own fiber and never mixed into the protocol
  # stream: servers log to stderr freely, and a single stray line on the wrong
  # stream would otherwise desynchronise the connection.
  class StdioTransport < Transport
    # How many stderr lines to keep. Enough to explain a failed handshake,
    # little enough that a chatty server cannot grow the process.
    STDERR_TAIL = 20

    # Time a terminated server gets to exit before it is killed outright.
    GRACE = 3.seconds

    # How long `close` waits for the stderr drain to reach the end of the pipe
    # before closing it anyway. It is reached, not waited out: by this point
    # the process has been signalled and what it wrote is already sitting in
    # the pipe buffer, so the fiber needs one turn to read it and see EOF. The
    # cap is for the case where it will not come at all — a process that
    # survived SIGKILL long enough to hold the write end open — because losing
    # a server's last words is better than never shutting down.
    STDERR_GRACE = 250.milliseconds

    getter stderr_tail : Array(String)

    # How long SIGTERM gets before SIGKILL follows. Zero sends both at once,
    # which is what a caller on a deadline needs: `smith doctor` promises to
    # be quick, waiting twice over for a server that ignores TERM is how it
    # would break that promise, and nothing a probe started has state worth
    # flushing. A session keeps the patient default.
    getter grace : Time::Span

    @status : Process::Status? = nil
    @closed = false

    def self.spawn_server(
      command : String,
      args : Array(String) = [] of String,
      env : Hash(String, String) = Hash(String, String).new,
      chdir : String? = nil,
      grace : Time::Span = GRACE,
    ) : StdioTransport
      process = Process.new(
        command,
        args,
        env: env.empty? ? nil : env,
        chdir: chdir,
        shell: false,
        input: Process::Redirect::Pipe,
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe
      )

      new(process, grace)
    end

    def initialize(@process : Process, @grace : Time::Span = GRACE)
      @stderr_tail = Array(String).new
      @done = Channel(Nil).new(1)
      # Closed rather than sent to: the end of the drain is a fact, not a
      # message, and every later reader has to be able to observe it. A send
      # would be taken by whoever asked first and leave the next caller
      # waiting out the cap for something that already happened.
      @drained = Channel(Nil).new

      spawn do
        # Draining comes first, and this is why: `Process#wait` closes all
        # three pipes on its way out (`ensure close`), so calling it is what
        # ends the drain — not by reaching the end of stderr but by pulling
        # the file descriptor out from under it, discarding whatever the
        # process wrote and had not been read yet. Two fibers were racing for
        # the same descriptor, and the winner decided whether a server that
        # explains itself and exits is quoted or misquoted as silent.
        #
        # Waiting here is not a delay: stderr reaches its end when the last
        # write end closes, which is when the process exits — the same event
        # `wait` is about to report. It costs a hop, not a wait.
        #
        # Nothing deadlocks if the end never comes — a grandchild that
        # inherited stderr and outlives its parent is the case — because
        # `close` closes the descriptor itself once its grace runs out, which
        # ends the drain and releases this fiber to reap.
        @drained.receive?
        @status = @process.wait
        @done.send(nil)
      end

      spawn do
        begin
          while line = @process.error.gets
            @stderr_tail << line
            @stderr_tail.shift if @stderr_tail.size > STDERR_TAIL
          end
        rescue IO::Error
          # The process is gone; nothing left to drain.
        ensure
          @drained.close
        end
      end
    end

    def alive? : Bool
      @status.nil?
    end

    def send(line : String) : Nil
      @process.input.puts(line)
      @process.input.flush
    rescue ex : IO::Error
      raise ConnectionError.new("could not write to the MCP server: #{ex.message}")
    end

    def receive : String?
      @process.output.gets
    rescue IO::Error
      nil
    end

    # The drain fiber is done, or the cap ran out. A closed channel answers
    # every caller and answers again, so asking twice costs nothing.
    def await_stderr : Nil
      select
      when @drained.receive?
      when timeout(STDERR_GRACE)
      end
    end

    # SIGTERM, then SIGKILL. Both are needed: a server that ignores TERM would
    # otherwise be left behind as an orphan holding whatever it opened.
    def close : Nil
      return if @closed
      @closed = true

      close_pipe(@process.input)

      if alive?
        signal(Signal::TERM)
        signal(Signal::KILL) unless exited?(@grace)
        exited?(@grace)
      end

      # Before the read end goes, not after: what the process wrote is in the
      # pipe buffer, and closing this side discards whatever has not been read
      # yet. A server that fails by writing to stderr and exiting at once —
      # the commonest way a misconfigured one fails — writes its explanation
      # into that buffer and dies before smith's first write returns, so the
      # drain fiber may not have been scheduled even once. Closing here first
      # is what threw the explanation away, and only sometimes: whether the
      # fiber got a turn depended on whether the write blocked, which is why
      # it read as a flake rather than as the loss it is.
      await_stderr

      close_pipe(@process.output)
      close_pipe(@process.error)
    end

    private def exited?(span : Time::Span) : Bool
      return true unless alive?
      # A zero grace is not a zero-length wait but no wait at all: the caller
      # asked for TERM and KILL together, and SIGKILL cannot be ignored, so
      # there is nothing left to wait for.
      return false unless span > Time::Span.zero

      select
      when @done.receive
        true
      when timeout(span)
        false
      end
    end

    private def signal(sig : Signal) : Nil
      @process.signal(sig)
    rescue
      # Already gone between the check and the signal.
    end

    private def close_pipe(io : IO) : Nil
      io.close
    rescue
    end
  end
end
