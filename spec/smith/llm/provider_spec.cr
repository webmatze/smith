require "../../spec_helper"
require "socket"

describe Smith::LLM::Timeouts do
  it "defaults to the [http] values from Smith::Config" do
    timeouts = Smith::LLM::Timeouts.default

    timeouts.connect.should eq(Smith::Config::DEFAULT_CONNECT_TIMEOUT.seconds)
    timeouts.read.should eq(Smith::Config::DEFAULT_READ_TIMEOUT.seconds)
  end

  it "converts second counts into spans" do
    timeouts = Smith::LLM::Timeouts.from_seconds(3, 45)

    timeouts.connect.should eq(3.seconds)
    timeouts.read.should eq(45.seconds)
  end
end

private class CannedProvider < Smith::LLM::Provider
  getter completions = 0

  def name : String
    "canned"
  end

  def default_model : String
    "canned-model"
  end

  def complete(request : Smith::LLM::Request) : Smith::LLM::Response
    @completions += 1

    Smith::LLM::Response.new(
      id: "canned-1",
      model: default_model,
      content: [
        Smith::LLM::ContentBlock.text("first block"),
        Smith::LLM::ContentBlock.tool_use("c1", "bash", JSON.parse(%({"command": "ls"}))),
        Smith::LLM::ContentBlock.text("second block"),
      ],
      stop_reason: "stop"
    )
  end
end

describe Smith::LLM::Provider do
  describe "the non-streaming default" do
    # This default is what makes deltas universal: callers never have to ask
    # whether the provider streams.
    it "yields one delta per text block and returns the same response" do
      provider = CannedProvider.new
      request = Smith::LLM::Request.new(model: "m", messages: [Smith::LLM::Message.user("hi")])

      deltas = [] of String
      response = provider.complete_streaming(request) { |chunk| deltas << chunk }

      deltas.should eq(["first block", "second block"])
      provider.completions.should eq(1)
      response.id.should eq("canned-1")
      response.content.size.should eq(3)
      response.content[1].tool_name.should eq("bash")
    end
  end

  it "gives providers the default timeouts when none are passed" do
    provider = Smith::LLM::Ollama.new(host: "http://localhost:11434")

    provider.timeouts.connect.should eq(Smith::Config::DEFAULT_CONNECT_TIMEOUT.seconds)
    provider.timeouts.read.should eq(Smith::Config::DEFAULT_READ_TIMEOUT.seconds)
  end

  it "carries explicitly passed timeouts" do
    provider = Smith::LLM::Ollama.new(
      host: "http://localhost:11434",
      timeouts: Smith::LLM::Timeouts.from_seconds(7, 99)
    )

    provider.timeouts.connect.should eq(7.seconds)
    provider.timeouts.read.should eq(99.seconds)
  end

  # HTTP::Client exposes timeout setters but no getters, so the wiring can only
  # be proven by observing the behaviour: a server that accepts the connection
  # and then says nothing at all must be abandoned, not waited on forever.
  it "gives up on a silent server once the read timeout elapses" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port

    spawn do
      if socket = server.accept?
        sleep 5.seconds
        socket.close
      end
    rescue
      # Server closed underneath us during teardown — nothing to do.
    end

    provider = Smith::LLM::Ollama.new(
      host: "http://127.0.0.1:#{port}",
      timeouts: Smith::LLM::Timeouts.new(1.second, 50.milliseconds)
    )

    request = Smith::LLM::Request.new(
      model: "probe-model",
      messages: [Smith::LLM::Message.user("hi")]
    )

    started = Time.instant
    expect_raises(IO::TimeoutError) { provider.complete(request) }
    elapsed = Time.instant - started

    # One attempt, not four: proves the retry exclusion holds end to end.
    # Four tries plus backoff would take well over a second.
    elapsed.should be < 500.milliseconds
  ensure
    server.try(&.close)
  end
end
