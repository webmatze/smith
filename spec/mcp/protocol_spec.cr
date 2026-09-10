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

describe Smith::MCP::StdioTransport do
  # A server's complaint on stderr is the whole answer to "why will this not
  # start", and closing the transport is what lost it: the bytes sit in the
  # pipe until the drain fiber reads them, and closing the read end throws
  # away whatever is still there. Whether anything survived came down to
  # whether that fiber had been given a turn since the bytes arrived, which is
  # why the loss showed up as an occasional red CI job rather than as a
  # missing feature.
  #
  # Racing for that state would be the same coin toss, so it is built instead.
  # The child is watched to the point where it has written — before the
  # transport, and therefore before the drain fiber, exists at all, which is
  # what makes waiting here safe: there is nothing yet that could drain it.
  # `grace: 0` then leaves `close` with nothing to wait for and so no reason to
  # yield, which is what `smith doctor` asks for; any yield in there would hand
  # the fiber a turn by accident and the spec would pass for a reason that has
  # nothing to do with the fix.
  it "keeps what a server wrote to stderr when nothing has drained it yet" do
    script = File.tempname("smith-mcp-lastwords", ".sh")
    written = File.tempname("smith-mcp-lastwords", ".written")
    process = nil

    begin
      File.write(script, <<-SH)
        #!/bin/sh
        echo 'TOKEN-from-the-child' >&2
        touch "#{written}"
        exit 1
        SH
      File.chmod(script, 0o755)

      process = Process.new(
        script,
        shell: false,
        input: Process::Redirect::Pipe,
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe
      )

      100.times do
        break if File.exists?(written)
        sleep 10.milliseconds
      end
      File.exists?(written).should be_true

      transport = Smith::MCP::StdioTransport.new(process, grace: Time::Span.zero)
      transport.close

      transport.stderr_tail.join(" ").should contain("TOKEN-from-the-child")
    ensure
      # The assertion above can fail before `close` has run, and a child that
      # nothing signals outlives the spec run.
      process.try do |running|
        running.terminate rescue nil
        running.wait rescue nil
      end
      File.delete(script) if File.exists?(script)
      File.delete(written) if File.exists?(written)
    end
  end
end
