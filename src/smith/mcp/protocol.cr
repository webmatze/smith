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

    def initialize(@code : Int32, message : String)
      super(message)
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
    # error it was. Read once, when the pending callers are abandoned.
    def failure_hint : String?
      nil
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

      spawn do
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
