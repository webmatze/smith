require "json"
require "../../../src/smith/mcp"

# An MCP server that never leaves the process.
#
# The interesting part of the client is the reader fiber: requests overtake
# each other, and a response has to reach the caller that asked for it rather
# than the one that happens to be waiting. Driving that from a real subprocess
# would make the timing unrepeatable, so the transport is swapped instead.
#
# The process-level concerns — orphans, restarts, a command that is not a
# server at all — are covered against a real stdio process in manager_spec.
class FakeTransport < Smith::MCP::Transport
  # What the client wrote, in order. Lets a spec assert on the framing itself.
  getter sent : Array(String)

  # Called in the sending fiber. The fake server answers from here; anything
  # that needs to be slow has to spawn.
  property on_send : Proc(String, Nil)?

  getter? closed : Bool

  def initialize
    # Buffered, so answering from inside `send` cannot deadlock against the
    # reader fiber that has not been scheduled yet.
    @outbox = Channel(String?).new(64)
    @sent = Array(String).new
    @lock = Mutex.new
    @closed = false
  end

  def send(line : String) : Nil
    raise Smith::MCP::ConnectionError.new("transport is closed") if @closed

    @lock.synchronize { @sent << line }
    @on_send.try &.call(line)
  end

  def receive : String?
    @outbox.receive
  end

  def close : Nil
    return if @closed
    @closed = true
    @outbox.send(nil)
  end

  # Server side: push one line towards the client.
  def emit(line : String) : Nil
    @outbox.send(line)
  end

  # Server side: end of stream, as a crashed process would look.
  def die : Nil
    @closed = true
    @outbox.send(nil)
  end
end

class FakeServer
  DEFAULT_TOOLS = %({"tools": [
    {"name": "echo", "description": "Echo text back", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}}
  ]})

  getter transport : FakeTransport

  # Every id the server was asked something on, in arrival order.
  getter calls : Array(Int64)

  property tools_result : String = DEFAULT_TOOLS

  # Takes over `tools/call`. Without one, every call answers "ok" at once.
  property on_call : Proc(Int64, String, JSON::Any, Nil)?

  def initialize
    @transport = FakeTransport.new
    @calls = Array(Int64).new
    @transport.on_send = ->(line : String) { dispatch(line) }
  end

  def client(
    name : String = "fake",
    timeout : Time::Span = 5.seconds,
    startup_timeout : Time::Span = 5.seconds,
  ) : Smith::MCP::Client
    Smith::MCP::Client.new(name, @transport, timeout, startup_timeout)
  end

  # A started client, handshake and tools/list done.
  def connected(**options) : Smith::MCP::Client
    client(**options).tap(&.start)
  end

  def reply(id : Int64, result : String) : Nil
    @transport.emit(%({"jsonrpc": "2.0", "id": #{id}, "result": #{result}}))
  end

  def reply_error(id : Int64, code : Int32, message : String) : Nil
    @transport.emit(%({"jsonrpc": "2.0", "id": #{id}, "error": {"code": #{code}, "message": #{message.to_json}}}))
  end

  def emit(line : String) : Nil
    @transport.emit(line)
  end

  def die : Nil
    @transport.die
  end

  def text_result(id : Int64, text : String, error : Bool = false) : Nil
    reply(id, %({"content": [{"type": "text", "text": #{text.to_json}}], "isError": #{error}}))
  end

  private def dispatch(line : String) : Nil
    request = JSON.parse(line)
    method = request["method"]?.try(&.as_s?)
    id = request["id"]?.try(&.as_i64?)

    case method
    when "initialize"
      reply(id.not_nil!, %({"protocolVersion": "2024-11-05", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1.0"}}))
    when "notifications/initialized"
      # A notification: no answer by protocol.
    when "tools/list"
      reply(id.not_nil!, @tools_result)
    when "tools/call"
      params = request["params"]
      @calls << id.not_nil!

      handler = @on_call
      if handler
        handler.call(id.not_nil!, params["name"].as_s, params["arguments"])
      else
        text_result(id.not_nil!, "ok")
      end
    end
  end
end
