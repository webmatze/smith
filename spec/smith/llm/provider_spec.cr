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

describe Smith::LLM::Provider do
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
