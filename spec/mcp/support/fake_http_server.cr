require "json"
require "http/server"
require "../../../src/smith/mcp"

# An MCP server that speaks Streamable HTTP on a local port, entirely inside
# the test process. No external service, nothing to install — the same promise
# the stdio fake made.
#
# It answers JSON-RPC requests posted to it. Two response shapes are covered,
# because the spec requires clients to accept both:
#
# - a plain `application/json` body (the default), and
# - a `text/event-stream` body when `@sse` is on.
#
# What is asserted against it: the headers it saw (auth, session id) are
# recorded per request, so a spec can check what actually went over the wire.
class FakeHttpServer
  # What the server received, in order. Lets a spec assert on headers and
  # bodies rather than guessing from the result.
  record Seen, method : String, path : String, headers : Hash(String, String), body : String

  getter seen : Array(Seen)
  getter url : String

  # The session id the server hands out — one for the whole server unless a
  # spec replaces it.
  property session_id : String = "fake-session"

  # Answer as an SSE stream instead of a JSON body.
  property? sse : Bool = false

  # With `sse`: after writing the answer to a `tools/call`, hold the stream
  # open for this long rather than closing it. Real servers do this — the
  # stream doubles as an event channel — and a client that reads to EOF would
  # sit here instead of delivering the answer. The handshake is never held, so
  # a client can still start up.
  property hold_call_stream : Time::Span = 0.seconds

  # Require this exact Authorization header on every request. Anything else
  # gets a 401 — the wrong-credentials path.
  property required_auth : String? = nil

  # Answer every request with this status. Overwrites everything; used for
  # the "server answers garbage" path.
  property force_status : Int32? = nil

  # Fail the next `tools/call` with a 500, then serve normally — the crash
  # the restart-once spec needs, against the same url.
  property? fail_next_call : Bool = false

  # Fail *every* `tools/call` with a 500 — the restart happens and fails the
  # same way, which is what gets a server's tools withdrawn. The handshake
  # still succeeds, so the server does start.
  property? fail_all_calls : Bool = false

  property tools_result : String = %({"tools": [
    {"name": "echo", "description": "Echo text back", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}}
  ]})

  # Takes over `tools/call`: given the id, tool name and arguments, it returns
  # the JSON-RPC response to send. Without one, every call answers "pong".
  property on_call : Proc(Int64, String, JSON::Any, String)? = nil

  @server : HTTP::Server
  @addr : Socket::IPAddress

  def initialize
    @seen = Array(Seen).new
    @server = build_server
    @addr = @server.bind_tcp("127.0.0.1", 0)
    spawn @server.listen
    @url = "http://127.0.0.1:#{@addr.port}/mcp"
  end

  def stop : Nil
    @server.close
  end

  def text_result(id : Int64, text : String, error : Bool = false) : String
    %({"jsonrpc": "2.0", "id": #{id}, "result": {"content": [{"type": "text", "text": #{text.to_json}}], "isError": #{error}}})
  end

  private def build_server : HTTP::Server
    HTTP::Server.new do |ctx|
      handle(ctx)
    end
  end

  private def handle(ctx : HTTP::Server::Context) : Nil
    method = ctx.request.method
    path = ctx.request.resource

    if method == "DELETE"
      # Ending the session: the client should send the session id along.
      @seen << Seen.new(method, path, headers_of(ctx), "")
      ctx.response.status = HTTP::Status::OK
      return
    end

    body = ctx.request.body.try(&.gets_to_end) || ""
    @seen << Seen.new(method, path, headers_of(ctx), body)

    if status = @force_status
      ctx.response.status = HTTP::Status.from_value(status)
      ctx.response.print("nope")
      return
    end

    if required = @required_auth
      unless ctx.request.headers["Authorization"]? == required
        ctx.response.status = HTTP::Status::UNAUTHORIZED
        ctx.response.print("unauthorized")
        return
      end
    end

    request = JSON.parse(body)
    rpc_method = request["method"]?.try(&.as_s?)
    id = request["id"]?.try(&.as_i64?)

    response = case rpc_method
               when "initialize"
                 %({"jsonrpc": "2.0", "id": #{id.not_nil!}, "result": {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}}, "serverInfo": {"name": "httpfake", "version": "1.0"}}})
               when "notifications/initialized"
                 nil # no answer by protocol
               when "tools/list"
                 %({"jsonrpc": "2.0", "id": #{id.not_nil!}, "result": #{@tools_result}})
               when "tools/call"
                 if @fail_next_call
                   @fail_next_call = false
                   ctx.response.status = HTTP::Status::INTERNAL_SERVER_ERROR
                   ctx.response.print("crash")
                   return
                 end

                 if @fail_all_calls
                   ctx.response.status = HTTP::Status::INTERNAL_SERVER_ERROR
                   ctx.response.print("crash")
                   return
                 end

                 params = request["params"]
                 handler = @on_call
                 if handler
                   handler.call(id.not_nil!, params["name"].as_s, params["arguments"])
                 else
                   text_result(id.not_nil!, "pong")
                 end
               else
                 nil
               end

    # A notification the fake does not answer, or an unknown method: nothing.
    return if response.nil?

    ctx.response.status = HTTP::Status::OK
    ctx.response.headers["Mcp-Session-Id"] = @session_id

    # Holding applies to tool calls only — the handshake has to succeed so a
    # client can start up against this server at all.
    hold = rpc_method == "tools/call" ? @hold_call_stream : 0.seconds

    if @sse
      one_line = JSON.parse(response).to_json
      payload = "event: message\ndata: #{one_line}\n\n"
      ctx.response.content_type = "text/event-stream"

      if hold > 0.seconds
        # No content length: the body is chunked and the connection stays
        # open until the handler returns.
        ctx.response.print payload
        ctx.response.flush
        sleep hold
      else
        # A finished SSE body needs a content length — a chunked one that the
        # handler merely returns from does not terminate for the client.
        ctx.response.content_length = payload.bytesize
        ctx.response.print payload
      end
    else
      ctx.response.content_type = "application/json"
      ctx.response.print response
    end
  end

  private def headers_of(ctx : HTTP::Server::Context) : Hash(String, String)
    result = Hash(String, String).new
    ctx.request.headers.each { |key, values| result[key] = values.join(", ") }
    result
  end
end
