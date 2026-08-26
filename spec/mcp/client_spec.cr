require "spec"
require "./support/fake_server"

describe Smith::MCP::Client do
  it "performs the handshake and lists tools" do
    server = FakeServer.new
    client = server.connected

    methods = server.transport.sent.compact_map { |line| JSON.parse(line)["method"]?.try(&.as_s) }
    methods.should eq(["initialize", "notifications/initialized", "tools/list"])

    client.server_info.should eq("fake 1.0")
    client.tools.map(&.name).should eq(["echo"])
    client.tools.first.description.should eq("Echo text back")
  end

  it "announces the protocol version and itself in the handshake" do
    server = FakeServer.new
    server.connected

    params = JSON.parse(server.transport.sent.first)["params"]
    params["protocolVersion"].as_s.should eq(Smith::MCP::PROTOCOL_VERSION)
    params["clientInfo"]["name"].as_s.should eq("smith")
  end

  it "calls a tool and flattens the text blocks" do
    server = FakeServer.new
    server.on_call = ->(id : Int64, _tool : String, args : JSON::Any) do
      server.reply(id, %({"content": [{"type": "text", "text": "hello #{args["who"].as_s}"}, {"type": "text", "text": "again"}]}))
    end

    result = server.connected.call_tool("echo", JSON.parse(%({"who": "world"})))

    result.error?.should be_false
    result.text.should eq("hello world\nagain")
  end

  it "reports a tool error result without raising" do
    server = FakeServer.new
    server.on_call = ->(id : Int64, _tool : String, _args : JSON::Any) do
      server.text_result(id, "file not found", error: true)
    end

    result = server.connected.call_tool("echo", JSON.parse("{}"))

    result.error?.should be_true
    result.text.should eq("file not found")
  end

  it "raises the JSON-RPC error a server answers with" do
    server = FakeServer.new
    server.on_call = ->(id : Int64, _tool : String, _args : JSON::Any) do
      server.reply_error(id, -32602, "unknown tool")
    end

    expect_raises(Smith::MCP::RpcError, "unknown tool") do
      server.connected.call_tool("nope", JSON.parse("{}"))
    end
  end

  # The core of the whole transport: two calls are in flight, the server
  # answers the second one first, and each caller still gets its own result.
  it "matches concurrent responses by id, not by arrival order" do
    server = FakeServer.new
    pending = Array(Int64).new

    server.on_call = ->(id : Int64, _tool : String, _args : JSON::Any) do
      pending << id

      if pending.size == 2
        # Deliberately reversed.
        server.text_result(pending[1], "second")
        server.text_result(pending[0], "first")
      end
    end

    client = server.connected
    results = Channel({String, String}).new(2)

    spawn { results.send({"a", client.call_tool("echo", JSON.parse(%({"n": 1}))).text}) }
    spawn { results.send({"b", client.call_tool("echo", JSON.parse(%({"n": 2}))).text}) }

    collected = Hash(String, String).new
    2.times do
      label, text = results.receive
      collected[label] = text
    end

    collected["a"].should eq("first")
    collected["b"].should eq("second")
  end

  it "gives up on a call the server never answers" do
    server = FakeServer.new
    server.on_call = ->(_id : Int64, _tool : String, _args : JSON::Any) { }

    client = server.connected(timeout: 100.milliseconds)

    expect_raises(Smith::MCP::TimeoutError, /did not answer tools\/call/) do
      client.call_tool("echo", JSON.parse("{}"))
    end
  end

  # A timeout must not leave the id behind: the next call would otherwise be
  # handed the late answer to the abandoned one.
  it "does not deliver a late answer to the next call" do
    server = FakeServer.new
    server.on_call = ->(id : Int64, _tool : String, _args : JSON::Any) do
      # The first call is answered far too late; the second at once.
      if server.calls.size == 1
        spawn do
          sleep 300.milliseconds
          server.text_result(id, "too late")
        end
      else
        server.text_result(id, "on time")
      end
    end

    client = server.connected(timeout: 100.milliseconds)

    expect_raises(Smith::MCP::TimeoutError) { client.call_tool("echo", JSON.parse("{}")) }
    client.call_tool("echo", JSON.parse("{}")).text.should eq("on time")
  end

  it "fails a call in flight when the server dies" do
    server = FakeServer.new
    server.on_call = ->(_id : Int64, _tool : String, _args : JSON::Any) { server.die }

    expect_raises(Smith::MCP::ConnectionError, /closed the connection/) do
      server.connected.call_tool("echo", JSON.parse("{}"))
    end
  end

  it "ignores a stray log line on stdout" do
    server = FakeServer.new
    server.on_call = ->(id : Int64, _tool : String, _args : JSON::Any) do
      server.emit("INFO  handling request")
      server.text_result(id, "still fine")
    end

    server.connected.call_tool("echo", JSON.parse("{}")).text.should eq("still fine")
  end

  it "registers a tool whose schema uses nested $refs" do
    server = FakeServer.new
    server.tools_result = %({"tools": [{
      "name": "query",
      "description": "Run a query",
      "inputSchema": {
        "type": "object",
        "properties": {"filter": {"$ref": "#/$defs/filter"}},
        "$defs": {"filter": {"type": "object", "properties": {"nested": {"$ref": "#/$defs/filter"}}}}
      }
    }]})

    schema = server.connected.tools.first.input_schema

    schema["properties"]["filter"]["$ref"].as_s.should eq("#/$defs/filter")
    schema["$defs"]["filter"]["properties"]["nested"]["$ref"].as_s.should eq("#/$defs/filter")
  end

  it "gives a tool without a schema one a provider will accept" do
    server = FakeServer.new
    server.tools_result = %({"tools": [{"name": "ping"}]})

    definition = server.connected.tools.first
    definition.input_schema["type"].as_s.should eq("object")
    definition.description.should contain("ping")
  end

  it "drops a duplicate tool name from the same server" do
    server = FakeServer.new
    server.tools_result = %({"tools": [
      {"name": "read", "description": "first"},
      {"name": "read", "description": "second"}
    ]})

    tools = server.connected.tools
    tools.size.should eq(1)
    tools.first.description.should eq("first")
  end

  it "follows nextCursor so a paginated tool list is complete" do
    server = FakeServer.new
    page = 0

    server.transport.on_send = ->(line : String) do
      request = JSON.parse(line)
      id = request["id"]?.try(&.as_i64)

      case request["method"]?.try(&.as_s)
      when "initialize"
        server.reply(id.not_nil!, %({"protocolVersion": "2024-11-05", "capabilities": {}}))
      when "tools/list"
        page += 1
        if page == 1
          server.reply(id.not_nil!, %({"tools": [{"name": "one"}], "nextCursor": "p2"}))
        else
          request["params"]["cursor"].as_s.should eq("p2")
          server.reply(id.not_nil!, %({"tools": [{"name": "two"}]}))
        end
      end
    end

    server.client.tap(&.start).tools.map(&.name).should eq(["one", "two"])
  end

  it "keeps structured-only content rather than reporting an empty result" do
    server = FakeServer.new
    server.on_call = ->(id : Int64, _tool : String, _args : JSON::Any) do
      server.reply(id, %({"content": [], "structuredContent": {"rows": 2}}))
    end

    server.connected.call_tool("echo", JSON.parse("{}")).text.should eq(%({"rows":2}))
  end

  it "attaches an image block and names it in the text" do
    server = FakeServer.new
    server.on_call = ->(id : Int64, _tool : String, _args : JSON::Any) do
      server.reply(id, %({"content": [{"type": "image", "mimeType": "image/png", "data": "iVBORw0KGgo="}]}))
    end

    result = server.connected.call_tool("echo", JSON.parse("{}"))

    result.media.size.should eq(1)
    result.media.first.media_type.should eq("image/png")
    result.media.first.data.should eq("iVBORw0KGgo=")
    result.text.should contain("image/png")
    # The payload belongs in the block, never in the text — that is the whole
    # difference between attaching a picture and pasting base64 into the
    # window.
    result.text.should_not contain("iVBORw0KGgo=")
  end

  it "goes by the bytes, not by the mimeType the server claims" do
    server = FakeServer.new
    server.on_call = ->(id : Int64, _tool : String, _args : JSON::Any) do
      # Valid base64, but "hello" is no image. A claim about a payload is not
      # the payload.
      server.reply(id, %({"content": [{"type": "image", "mimeType": "image/png", "data": "aGVsbG8="}]}))
    end

    result = server.connected.call_tool("echo", JSON.parse("{}"))

    result.media.should be_empty
    result.text.should contain("image/png")
    result.text.should contain("not shown")
  end

  it "caps how many images one call may hand back, and says how many it dropped" do
    png = "iVBORw0KGgo="
    blocks = Array.new(6) { %({"type": "image", "mimeType": "image/png", "data": "#{png}"}) }

    server = FakeServer.new
    server.on_call = ->(id : Int64, _tool : String, _args : JSON::Any) do
      server.reply(id, %({"content": [#{blocks.join(",")}]}))
    end

    result = server.connected.call_tool("echo", JSON.parse("{}"))

    result.media.size.should eq(Smith::MCP::ToolResult::MAX_ATTACHMENTS)
    result.text.should contain("2 further images were not attached")
  end

  it "names a content type it cannot carry instead of dropping it" do
    server = FakeServer.new
    server.on_call = ->(id : Int64, _tool : String, _args : JSON::Any) do
      server.reply(id, %({"content": [{"type": "audio", "mimeType": "audio/wav", "data": "AAAA"}]}))
    end

    result = server.connected.call_tool("echo", JSON.parse("{}"))

    # It used to return nil here, which deleted the block from the result
    # without a word and left a successful call looking empty.
    result.text.should contain("audio")
    result.text.should contain("audio/wav")
    result.text.should_not eq("(empty result)")
  end
end
