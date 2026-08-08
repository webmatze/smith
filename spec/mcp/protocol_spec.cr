require "spec"
require "../../src/smith/mcp/protocol"

describe Smith::MCP::Protocol do
  it "frames a request as JSON-RPC 2.0" do
    line = Smith::MCP::Protocol.request(7_i64, "tools/list")
    json = JSON.parse(line)

    json["jsonrpc"].as_s.should eq("2.0")
    json["id"].as_i64.should eq(7)
    json["method"].as_s.should eq("tools/list")
    json.as_h.has_key?("params").should be_false
  end

  it "frames a notification without an id" do
    json = JSON.parse(Smith::MCP::Protocol.notification("notifications/initialized"))

    json.as_h.has_key?("id").should be_false
    json["method"].as_s.should eq("notifications/initialized")
  end

  it "never embeds a raw newline, so line framing holds" do
    params = JSON.parse(%({"text": "one\\ntwo"}))
    line = Smith::MCP::Protocol.request(1_i64, "tools/call", params)

    line.lines.size.should eq(1)
    JSON.parse(line)["params"]["text"].as_s.should eq("one\ntwo")
  end
end

describe Smith::MCP::Message do
  it "reads a result" do
    message = Smith::MCP::Message.parse(%({"jsonrpc": "2.0", "id": 3, "result": {"ok": true}})).not_nil!

    message.id.should eq(3)
    message.response?.should be_true
    message.result.not_nil!["ok"].as_bool.should be_true
    message.error.should be_nil
  end

  it "reads an error" do
    message = Smith::MCP::Message.parse(%({"jsonrpc": "2.0", "id": 3, "error": {"code": -32602, "message": "bad params"}})).not_nil!

    error = message.error.not_nil!
    error.code.should eq(-32602)
    error.message.should eq("bad params")
  end

  it "accepts a string id, which some servers echo back" do
    Smith::MCP::Message.parse(%({"jsonrpc": "2.0", "id": "12", "result": {}})).not_nil!.id.should eq(12)
  end

  it "treats a notification as something other than a response" do
    message = Smith::MCP::Message.parse(%({"jsonrpc": "2.0", "method": "notifications/message"})).not_nil!
    message.response?.should be_false
  end

  # A server logging to stdout instead of stderr must not take the connection
  # down — the line is dropped and the next one is read as usual.
  it "returns nil for a line that is not JSON" do
    Smith::MCP::Message.parse("starting server on port 3000...").should be_nil
    Smith::MCP::Message.parse("[1,2,3]").should be_nil
  end
end
