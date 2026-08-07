require "../../spec_helper"

private def response(stop : String?)
  Smith::LLM::Response.new("id", "model", [] of Smith::LLM::ContentBlock, stop_reason: stop)
end

describe Smith::LLM::StopReason do
  it "normalises the Anthropic spellings" do
    response("end_turn").stop.should eq(Smith::LLM::StopReason::EndTurn)
    response("tool_use").stop.should eq(Smith::LLM::StopReason::ToolUse)
    response("max_tokens").stop.should eq(Smith::LLM::StopReason::MaxTokens)
    response("stop_sequence").stop.should eq(Smith::LLM::StopReason::StopSequence)
  end

  it "normalises the OpenAI-shaped spellings, which Ollama and OpenRouter share" do
    response("stop").stop.should eq(Smith::LLM::StopReason::EndTurn)
    response("tool_calls").stop.should eq(Smith::LLM::StopReason::ToolUse)
    response("length").stop.should eq(Smith::LLM::StopReason::MaxTokens)
  end

  it "falls back to unknown for anything else" do
    response("content_filter").stop.should eq(Smith::LLM::StopReason::Unknown)
    response(nil).stop.should eq(Smith::LLM::StopReason::Unknown)
  end

  it "ignores case and surrounding space" do
    response(" MAX_TOKENS ").stop.should eq(Smith::LLM::StopReason::MaxTokens)
  end

  it "answers the question the agent actually asks" do
    response("length").stop.max_tokens?.should be_true
    response("stop").stop.max_tokens?.should be_false
  end
end

describe "the stop reason on the streaming paths" do
  it "comes through the OpenAI-shaped reader" do
    sse = <<-SSE
    data: {"choices":[{"delta":{"content":"hi"}}]}

    data: {"choices":[{"delta":{},"finish_reason":"length"}]}

    data: [DONE]

    SSE

    Smith::LLM::OpenAIStream.read(IO::Memory.new(sse), "m") { |_| }
      .stop.should eq(Smith::LLM::StopReason::MaxTokens)
  end

  it "comes through the Anthropic reader" do
    sse = <<-SSE
    data: {"type":"message_start","message":{"id":"m1","model":"claude-sonnet-5"}}

    data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":4}}

    data: [DONE]

    SSE

    Smith::LLM::AnthropicStream.read(IO::Memory.new(sse), "m") { |_| }
      .stop.should eq(Smith::LLM::StopReason::MaxTokens)
  end
end
