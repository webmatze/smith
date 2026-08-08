require "json"
require "./protocol"
require "../version"

module Smith::MCP
  # One tool as the server describes it. `input_schema` is passed to the
  # provider untouched — `LLM::ToolSpec#parameters` is a `JSON::Any`, so the
  # translation really is a hand-through, `$ref`s and all.
  struct ToolDefinition
    getter name : String
    getter description : String
    getter input_schema : JSON::Any

    def initialize(@name : String, @description : String, @input_schema : JSON::Any)
    end

    # A schema smith can hand to a provider. Servers omit `inputSchema`, send
    # `null`, or send a bare `{}` — all three mean "no arguments", and a
    # provider that receives them as-is may reject the whole request.
    def self.normalize_schema(value : JSON::Any?) : JSON::Any
      object = value.try(&.as_h?)
      return empty_schema if object.nil? || object.empty?
      return JSON::Any.new(object.merge({"type" => JSON::Any.new("object")})) unless object["type"]?

      JSON::Any.new(object)
    end

    private def self.empty_schema : JSON::Any
      JSON.parse(%({"type": "object", "properties": {}}))
    end

    def self.from_json(value : JSON::Any) : ToolDefinition?
      fields = value.as_h?
      return nil if fields.nil?

      name = fields["name"]?.try(&.as_s?)
      return nil if name.nil? || name.empty?

      ToolDefinition.new(
        name: name,
        description: fields["description"]?.try(&.as_s?) || "Tool '#{name}' provided by an MCP server.",
        input_schema: normalize_schema(fields["inputSchema"]?)
      )
    end
  end

  # What `tools/call` came back with, already flattened to text.
  struct ToolResult
    getter text : String
    getter? error : Bool

    def initialize(@text : String, @error : Bool = false)
    end

    def self.from_result(result : JSON::Any?) : ToolResult
      fields = result.try(&.as_h?)
      return new("(no result)") if fields.nil?

      parts = Array(String).new
      fields["content"]?.try(&.as_a?).try &.each do |block|
        rendered = render_block(block)
        parts << rendered unless rendered.nil?
      end

      # v2.0.21: servers may answer with structured data only. Dropping it
      # would turn a successful call into an empty one.
      if parts.empty?
        if structured = fields["structuredContent"]?
          parts << structured.to_json unless structured.raw.nil?
        end
      end

      new(
        parts.empty? ? "(empty result)" : parts.join("\n"),
        fields["isError"]?.try(&.as_bool?) || false
      )
    end

    # Only text is worth spending context on. Anything else is named so the
    # model knows something came back, without the bytes landing in the window.
    private def self.render_block(block : JSON::Any) : String?
      fields = block.as_h?
      return nil if fields.nil?

      case fields["type"]?.try(&.as_s?)
      when "text"
        fields["text"]?.try(&.as_s?)
      when "image"
        "[image: #{fields["mimeType"]?.try(&.as_s?) || "unknown type"}, not shown]"
      when "resource"
        resource = fields["resource"]?.try(&.as_h?)
        text = resource.try(&.["text"]?).try(&.as_s?)
        uri = resource.try(&.["uri"]?).try(&.as_s?) || "unknown"
        text || "[resource: #{uri}, not shown]"
      else
        nil
      end
    end
  end

  # A single MCP server connection: handshake, tool list, tool calls.
  #
  # One reader fiber owns the stream and hands each response to whoever is
  # waiting on that id. Nothing else may read from the transport — requests
  # overtake each other routinely, and matching by arrival order instead of by
  # id is exactly the bug that produces silently swapped tool results.
  class Client
    DEFAULT_TIMEOUT = 60.seconds

    # The handshake gets its own, shorter deadline. A command that is not an
    # MCP server at all — a typo, a plain `cat` — never answers, and the whole
    # session start would otherwise wait out the full call timeout for it.
    STARTUP_TIMEOUT = 10.seconds

    getter name : String
    getter tools : Array(ToolDefinition)
    getter server_info : String?

    @counter = 0_i64
    @closed = false

    def initialize(
      @name : String,
      @transport : Transport,
      @timeout : Time::Span = DEFAULT_TIMEOUT,
      @startup_timeout : Time::Span = STARTUP_TIMEOUT,
    )
      @tools = Array(ToolDefinition).new
      @pending = Hash(Int64, Channel(Message)).new
      @lock = Mutex.new
    end

    def start : Nil
      spawn read_loop

      handshake
      @tools = fetch_tools
    end

    def call_tool(tool : String, arguments : JSON::Any) : ToolResult
      params = JSON.parse(JSON.build do |json|
        json.object do
          json.field "name", tool
          json.field "arguments", arguments
        end
      end)

      ToolResult.from_result(request("tools/call", params, @timeout))
    end

    def close : Nil
      return if @closed
      @closed = true
      @transport.close
    end

    private def handshake : Nil
      # Empty capabilities: stage 1 offers the server nothing back — no
      # sampling, no roots — and announcing what smith cannot do would invite
      # requests it would have to refuse.
      params = JSON.parse(%({
        "protocolVersion": #{PROTOCOL_VERSION.to_json},
        "capabilities": {},
        "clientInfo": {"name": "smith", "version": #{Smith::VERSION.to_json}}
      }))

      result = request("initialize", params, @startup_timeout)

      @server_info = result.try(&.as_h?).try(&.["serverInfo"]?).try(&.as_h?).try do |info|
        [info["name"]?.try(&.as_s?), info["version"]?.try(&.as_s?)].compact.join(" ")
      end

      # Fire-and-forget by protocol: the server may start sending immediately
      # after it, and waiting for an answer that never comes would deadlock.
      @transport.send(Protocol.notification("notifications/initialized"))
    end

    # Paginated on purpose — a server with more tools than fit one page would
    # otherwise silently register only the first page.
    private def fetch_tools : Array(ToolDefinition)
      found = Array(ToolDefinition).new
      seen = Set(String).new
      cursor : String? = nil

      loop do
        params = cursor.try do |value|
          JSON.parse(JSON.build { |json| json.object { json.field "cursor", value } })
        end

        result = request("tools/list", params, @startup_timeout).try(&.as_h?)
        break if result.nil?

        result["tools"]?.try(&.as_a?).try &.each do |entry|
          definition = ToolDefinition.from_json(entry)
          next if definition.nil?
          # v2.0.31: a server exporting the same name twice would otherwise
          # register two tools that differ only in which one wins.
          next unless seen.add?(definition.name)
          found << definition
        end

        cursor = result["nextCursor"]?.try(&.as_s?)
        break if cursor.nil? || cursor.empty?
      end

      found
    end

    private def request(method : String, params : JSON::Any?, deadline : Time::Span) : JSON::Any?
      raise ConnectionError.new("the connection to MCP server '#{@name}' is closed") if @closed

      id = @lock.synchronize do
        @counter += 1
        @counter
      end

      # Buffered, so the reader fiber never blocks on a caller that has already
      # given up — and so a response arriving in the same tick as the timeout
      # is delivered rather than dropped.
      channel = Channel(Message).new(1)
      @lock.synchronize { @pending[id] = channel }

      begin
        @transport.send(Protocol.request(id, method, params))
      rescue ex
        @lock.synchronize { @pending.delete(id) }
        raise ex
      end

      select
      when message = channel.receive
        # The reader marks a lost connection by answering with an id-less
        # message. It has to become a ConnectionError rather than an RpcError:
        # only the former is worth a restart, and only the former is true here.
        raise ConnectionError.new(message.error.try(&.message) || "MCP server '#{@name}' closed the connection") if message.id.nil?

        if error = message.error
          raise error
        end
        message.result
      when timeout(deadline)
        @lock.synchronize { @pending.delete(id) }
        raise TimeoutError.new("MCP server '#{@name}' did not answer #{method} within #{deadline.total_seconds.to_i}s")
      end
    end

    # The single reader. Responses are matched by id, never by order.
    private def read_loop : Nil
      while line = @transport.receive
        message = Message.parse(line)
        next if message.nil? || !message.response?

        id = message.id
        next if id.nil?

        # Deleted under the lock, so a timeout that fires at the same moment
        # cannot leave the entry behind.
        channel = @lock.synchronize { @pending.delete(id) }
        channel.try &.send(message)
      end
    rescue
      # Falls through to the same cleanup as a clean EOF.
    ensure
      abandon_pending
    end

    # End of stream: every caller still waiting has to be told, or it would sit
    # there until its own timeout for a server that is already gone.
    private def abandon_pending : Nil
      waiting = @lock.synchronize do
        entries = @pending.values
        @pending.clear
        entries
      end

      dead = Message.new(
        id: nil,
        method: nil,
        result: nil,
        error: RpcError.new(0, "MCP server '#{@name}' closed the connection")
      )

      waiting.each { |channel| channel.send(dead) }
    end
  end
end
