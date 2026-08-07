require "../../spec_helper"

# Delays are irrelevant to what is under test here and would otherwise make the
# suite sleep for seconds.
private FAST_RETRY = Smith::LLM::Retry::Config.new(
  max_retries: 3,
  initial_delay: 1.millisecond,
  max_delay: 1.millisecond
)

describe Smith::LLM::Retry do
  it "does not retry an elapsed timeout" do
    attempts = 0

    expect_raises(IO::TimeoutError) do
      Smith::LLM::Retry.with_retry(FAST_RETRY) do
        attempts += 1
        raise IO::TimeoutError.new("read timed out")
      end
    end

    # The whole point: the caller waits read_timeout once, not four times over.
    attempts.should eq(1)
  end

  it "still retries connection-level errors" do
    attempts = 0

    expect_raises(Socket::ConnectError) do
      Smith::LLM::Retry.with_retry(FAST_RETRY) do
        attempts += 1
        raise Socket::ConnectError.new("connection refused")
      end
    end

    attempts.should eq(4) # initial attempt + 3 retries
  end

  it "still retries 429 and 5xx responses" do
    [429, 500, 503].each do |status|
      attempts = 0

      expect_raises(Smith::LLM::ResponseError) do
        Smith::LLM::Retry.with_retry(FAST_RETRY) do
          attempts += 1
          raise Smith::LLM::ResponseError.new(status, "boom")
        end
      end

      attempts.should eq(4)
    end
  end

  it "does not retry 4xx responses other than 429" do
    attempts = 0

    expect_raises(Smith::LLM::ResponseError) do
      Smith::LLM::Retry.with_retry(FAST_RETRY) do
        attempts += 1
        raise Smith::LLM::ResponseError.new(401, "unauthorized")
      end
    end

    attempts.should eq(1)
  end

  it "does not retry an error wrapped as Fatal, and unwraps it" do
    attempts = 0

    # Streaming uses this once a delta has reached the screen: replaying would
    # print the same text twice. Socket::ConnectError would normally retry.
    expect_raises(Socket::ConnectError, "stream died mid-flight") do
      Smith::LLM::Retry.with_retry(FAST_RETRY) do
        attempts += 1
        raise Smith::LLM::Retry::Fatal.new(Socket::ConnectError.new("stream died mid-flight"))
      end
    end

    attempts.should eq(1)
  end

  it "returns the value once a retried call succeeds" do
    attempts = 0

    result = Smith::LLM::Retry.with_retry(FAST_RETRY) do
      attempts += 1
      raise Socket::ConnectError.new("flaky") if attempts < 3
      "recovered"
    end

    result.should eq("recovered")
    attempts.should eq(3)
  end
end
