require "http/client"
require "uri"
require "./protocol"
require "./server_config"

module Smith::MCP
  # A Streamable-HTTP connection to a remote MCP server: JSON-RPC messages go
  # out as POSTs, answers come back either as a JSON body or as an SSE stream —
  # the spec requires the client to accept both, so both are read.
  #
  # Fitted into the same `Transport` interface stdio uses: `send` enqueues a
  # message and the answers land on `receive`, matched by id in the client's
  # reader fiber. That keeps the restart-once logic, the approval gate and the
  # untrusted marking exactly where they already are.
  class HttpTransport < Transport
    # Connecting to a host that routes into nowhere must not hang the session
    # start for the full call timeout.
    CONNECT_TIMEOUT = 10.seconds

    # Telling a server the session is over must never hold up shutdown — a
    # server that is already gone cannot be told anyway.
    CLOSE_TIMEOUT = 2.seconds

    getter failure_hint : String?
    getter failure_body : String?

    @session_id : String?
    @client : HTTP::Client

    # The only form of the url that is written into a message once this
    # constructor has returned. Built from the `URI` itself, so no such message
    # ever holds the whole one — where a filter run over a finished sentence
    # has to find the url again by shape, and a query holding a quote, an angle
    # bracket or a space ends the match early and leaves the rest of it
    # standing.
    #
    # The one exception is the constructor's own refusal below, which names the
    # raw url because a url with no host is exactly what it is reporting and
    # there is nothing left to call it by. That line reaches `smith mcp list`
    # and no further: it is cut to `(url)` by the filter in `Manager`, and both
    # of its callers rescue it, so it cannot become a tool result.
    @safe_url : String

    def initialize(
      @url : URI,
      @headers : Hash(String, String) = Hash(String, String).new,
      @read_timeout : Time::Span = Client::DEFAULT_TIMEOUT,
    )
      raise ConnectionError.new("'#{@url}' is not a usable MCP server url — no host") if @url.host.to_s.empty?

      @safe_url = ServerSpec.safe_url(@url.to_s)
      @inbox = Channel(String?).new(64)
      @session_id = nil
      @closed = false
      @failure_hint = nil
      @failure_body = nil
      @lock = Mutex.new
      @state_lock = Mutex.new
      @client = build_client
    end

    def send(line : String) : Nil
      # The failure message, not a generic one: by the time anyone writes
      # again, the transport usually knows what killed it.
      raise ConnectionError.new(@failure_hint || "the connection to the MCP server is closed") if @closed

      spawn do
        begin
          post(line)
        rescue ex
          # A spawned fiber must not raise out — the failure belongs to the
          # connection, and the waiting callers are told through the inbox.
          die!("the connection to the MCP server at #{@safe_url} broke: #{ex.message || ex.class.name}")
        end
      end
    end

    def receive : String?
      @inbox.receive
    end

    def close : Nil
      @state_lock.synchronize do
        return if @closed
        @closed = true
        @inbox.send(nil)
      end

      terminate_session
      close_client
    end

    # The POST itself. Serialised behind one mutex so the keep-alive socket
    # never serves two requests at once — smith's callers are serial in
    # practice anyway, but the socket is not safe if they ever are not.
    private def post(line : String) : Nil
      # Notifications get no answer by protocol; a request's response has to
      # be read out of the body or the stream, or the socket cannot be reused.
      request_id = JSON.parse(line).as_h?.try(&.["id"]?).try do |value|
        value.as_i64? || value.as_s?.try(&.to_i64?)
      end

      @lock.synchronize do
        return if @closed

        @client.post(@url.request_target, headers: request_headers, body: line) do |response|
          capture_session(response)

          case response.status_code
          when 200..299
            deliver(response, request_id)
          when 401, 403
            # The call got through and was refused — the one failure an
            # auth header can cause, and worth saying so plainly.
            drain(response)
            die!("the MCP server at #{@safe_url} refused the credentials (HTTP #{response.status_code})")
          when 404
            drain(response)
            die!("the MCP server at #{@safe_url} no longer recognises this session (HTTP 404) — it may have restarted")
          else
            body = response.body_io.gets_to_end
            # The status is smith's diagnosis; the body is the server's own
            # words. They travel separately so a caller that must not repeat
            # the second still gets the first.
            die!("the MCP server at #{@safe_url} answered HTTP #{response.status_code}", snippet(body))
          end
        end
      end
    rescue ex : IO::Error | OpenSSL::Error
      die!("could not reach the MCP server at #{@safe_url}: #{ex.message || ex.class.name}")
    end

    # The answer to a POST is either one JSON document or an SSE stream whose
    # events each carry one JSON-RPC message — both end up as lines on the
    # inbox, exactly as a stdio server would have written them.
    private def deliver(response : HTTP::Client::Response, request_id : Int64?) : Nil
      content_type = response.headers["Content-Type"]? || ""

      if content_type.includes?("text/event-stream")
        stream_sse(response.body_io, request_id)
      else
        body = response.body_io.gets_to_end
        @inbox.send(body) unless body.strip.empty?
      end
    end

    # Reads events one by one, handing each to the inbox, and stops once the
    # response for this request has arrived: a server may keep the stream open
    # for events smith has not subscribed to, and the socket must not sit
    # waiting on them until the read timeout.
    private def stream_sse(io : IO, request_id : Int64?) : Nil
      data = Array(String).new

      while line = io.gets
        unless line.empty?
          data << line[5..].lstrip if line.starts_with?("data:")
          next
        end

        next if data.empty?
        message = data.join("\n")
        data.clear

        @inbox.send(message)
        return if response_for?(message, request_id)
      end

      # A stream that ends without a final blank line still delivers its last
      # event.
      return if data.empty?

      @inbox.send(data.join("\n"))
    end

    private def response_for?(message : String, request_id : Int64?) : Bool
      return false if request_id.nil?

      Message.parse(message).try { |parsed| parsed.response? && parsed.id == request_id } || false
    end

    private def drain(response : HTTP::Client::Response) : Nil
      response.body_io.gets_to_end
    rescue IO::Error
    end

    # The server assigns a session id with the handshake; every later request
    # has to carry it, or a strict server answers 404.
    private def capture_session(response : HTTP::Client::Response) : Nil
      if id = response.headers["Mcp-Session-Id"]?
        @session_id = id unless id.empty?
      end
    end

    private def request_headers : HTTP::Headers
      headers = HTTP::Headers{
        "Content-Type" => "application/json",
        "Accept"       => "application/json, text/event-stream",
      }

      # Config headers last, so a configured Authorization (or anything else)
      # wins over the defaults.
      @headers.each { |key, value| headers[key] = value }

      if session_id = @session_id
        headers["Mcp-Session-Id"] = session_id
      end

      headers
    end

    # Connection-level failure: remember the reason, end the stream. Everyone
    # still waiting is abandoned by the reader and sees this message — the same
    # shape a dead stdio pipe produces.
    #
    # Every message that reaches here names the url, because where it was
    # trying to go is half the reason — and that url came out of `mcp.json`,
    # where userinfo, a path segment, a query and a fragment are each a place a
    # token is routinely written. Where it goes from here is why that matters:
    # `send` raises this line at the next write, `Client#abandon_pending` hands
    # it to every caller still waiting, and from there it is a tool result —
    # the model's context, `transcript.jsonl`, every `smith sessions export` of
    # the session. It outlives the run that made it.
    #
    # So the callers interpolate `@safe_url` and never `@url`: the whole url is
    # not written down and then found again, it is never written down. What is
    # left for `scrub_urls` here is the *other* source of a url in these lines
    # — an exception message from the HTTP client, which quotes what it was
    # given. A filter is the only tool available against that text, and it is
    # enough there: the url in it is one the stdlib composed, not one this
    # file's caller wrote, so the shapes that defeat a regex do not arise.
    #
    # `body` is not filtered and not merged: it is the server's own words, and
    # only a caller knows whether repeating them is the answer being looked for.
    private def die!(message : String, body : String? = nil) : Nil
      message = ServerSpec.scrub_urls(message)

      @state_lock.synchronize do
        @failure_hint ||= message
        @failure_body ||= body
        unless @closed
          @closed = true
          @inbox.send(nil)
        end
      end
    end

    # DELETE ends a Streamable-HTTP session by spec. Best effort — the session
    # ends with smith regardless, and a server that cannot be told is not
    # worth an error. On its own client, so an in-flight POST elsewhere never
    # shares a socket mid-request.
    private def terminate_session : Nil
      session_id = @session_id
      return if session_id.nil?

      client = HTTP::Client.new(@url)
      client.connect_timeout = CLOSE_TIMEOUT
      client.read_timeout = CLOSE_TIMEOUT

      headers = HTTP::Headers.new
      @headers.each { |key, value| headers[key] = value }
      headers["Mcp-Session-Id"] = session_id

      client.delete(@url.request_target, headers: headers)
    rescue
    end

    private def close_client : Nil
      @client.close
    rescue
    end

    private def build_client : HTTP::Client
      client = HTTP::Client.new(@url)
      client.connect_timeout = CONNECT_TIMEOUT
      # The per-call timeout from config doubles as the read deadline, so an
      # SSE stream that starts but never completes cannot outlive the call.
      client.read_timeout = @read_timeout
      client
    end

    private def snippet(body : String) : String
      text = body.strip
      text.size > 200 ? "#{text[0, 200]}…" : text
    end
  end
end
