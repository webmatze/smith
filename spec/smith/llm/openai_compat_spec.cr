require "../../spec_helper"
require "../../../src/smith/llm/ollama"
require "../../../src/smith/llm/openai"
require "../../../src/smith/llm/openrouter"

# The three OpenAI-shaped adapters build their payload the same way. Crystal's
# `private` is callable from a subclass without an explicit receiver, so these
# reach the real builder rather than a copy of it.
private class ProbeOllama < Smith::LLM::Ollama
  def payload_for(request : Smith::LLM::Request) : JSON::Any
    JSON.parse(build_payload("m", request))
  end
end

private class ProbeOpenAI < Smith::LLM::OpenAI
  def payload_for(request : Smith::LLM::Request) : JSON::Any
    JSON.parse(build_payload("m", request))
  end
end

private class ProbeOpenRouter < Smith::LLM::OpenRouter
  def payload_for(request : Smith::LLM::Request) : JSON::Any
    JSON.parse(build_payload("m", request))
  end
end

# A hash of the three probes would collapse to Provider+, which has no
# payload_for — so each adapter is wrapped in a uniformly typed proc.
private def probes
  [
    {"ollama", ->(r : Smith::LLM::Request) { ProbeOllama.new.payload_for(r) }},
    {"openai", ->(r : Smith::LLM::Request) { ProbeOpenAI.new(api_key: "k").payload_for(r) }},
    {"openrouter", ->(r : Smith::LLM::Request) { ProbeOpenRouter.new(api_key: "k").payload_for(r) }},
  ]
end

private def request_with(blocks : Array(Smith::LLM::ContentBlock)) : Smith::LLM::Request
  Smith::LLM::Request.new(
    model: "m",
    messages: [
      Smith::LLM::Message.user("hi"),
      Smith::LLM::Message.assistant_with_blocks(blocks),
    ]
  )
end

private def assistant_message(payload : JSON::Any) : JSON::Any
  payload["messages"].as_a.find { |m| m["role"].as_s == "assistant" }.not_nil!
end

describe "OpenAI-shaped assistant serialization" do
  it "sends an empty string, not null, for a message with neither text nor tool calls" do
    # A `content: null` message without tool_calls is rejected outright —
    # Ollama answers 400 "invalid message content type: <nil>" — and poisons
    # every later turn, since the transcript is resent each time.
    probes.each do |(name, probe)|
      message = assistant_message(probe.call(request_with(Array(Smith::LLM::ContentBlock).new)))

      message["content"].raw.should_not be_nil, "#{name} sent a null content"
      message["content"].as_s.should eq(""), "#{name}"
      message["tool_calls"]?.should be_nil, "#{name}"
    end
  end

  it "keeps content null alongside tool calls, which is the OpenAI convention" do
    probes.each do |(name, probe)|
      payload = probe.call(request_with([
        Smith::LLM::ContentBlock.tool_use("call_1", "write_file", JSON.parse(%({"path": "x"}))),
      ]))
      message = assistant_message(payload)

      message["content"].raw.should be_nil, "#{name}"
      message["tool_calls"].as_a.size.should eq(1), "#{name}"
    end
  end

  it "still sends text when there is any" do
    probes.each do |(name, probe)|
      payload = probe.call(request_with([Smith::LLM::ContentBlock.text("hello")]))

      assistant_message(payload)["content"].as_s.should eq("hello"), "#{name}"
    end
  end
end
