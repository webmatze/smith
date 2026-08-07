require "../../spec_helper"
require "../../../src/smith/llm/anthropic"
require "../../../src/smith/llm/ollama"
require "../../../src/smith/context"

private class ProbeAnthropic < Smith::LLM::Anthropic
  def payload_for(request : Smith::LLM::Request) : JSON::Any
    JSON.parse(build_payload("claude-sonnet-5", request))
  end

  def parse(body : String) : Smith::LLM::Response
    parse_response(body)
  end
end

private SIGNATURE = "ErUBCkYIARgCIkDx3s+Signature/Bytes=="

private def thinking_block(content : String = "Let me think.", signature : String? = SIGNATURE)
  Smith::LLM::ContentBlock.thinking(content, signature)
end

private def request_with(
  blocks : Array(Smith::LLM::ContentBlock),
  thinking_effort : String? = nil,
  thinking_budget : Int32? = nil,
  max_tokens : Int32? = nil,
)
  Smith::LLM::Request.new(
    model: "claude-sonnet-5",
    messages: [
      Smith::LLM::Message.user("hi"),
      Smith::LLM::Message.assistant_with_blocks(blocks),
    ],
    max_tokens: max_tokens,
    thinking_effort: thinking_effort,
    thinking_budget: thinking_budget
  )
end

describe "the thinking content block" do
  it "carries its text and signature" do
    block = thinking_block

    block.type.thinking?.should be_true
    block.text.should eq("Let me think.")
    block.signature.should eq(SIGNATURE)
  end

  it "keeps redacted thinking opaque" do
    block = Smith::LLM::ContentBlock.redacted_thinking("EncryptedPayload==")

    block.type.redacted_thinking?.should be_true
    block.text.should eq("EncryptedPayload==")
  end

  it "survives the session round-trip unchanged" do
    # smith resume would otherwise break for Anthropic the moment thinking is on.
    message = Smith::LLM::Message.assistant_with_blocks([thinking_block, Smith::LLM::ContentBlock.text("answer")])

    restored = Smith::LLM::Message.from_json(message.to_json)
    block = restored.content.first

    block.type.thinking?.should be_true
    block.text.should eq("Let me think.")
    block.signature.should eq(SIGNATURE)
  end

  it "deserializes a message saved before thinking existed" do
    old = %({"role":"assistant","content":[{"type":"text","text":"hi"}]})

    Smith::LLM::Message.from_json(old).content.first.signature.should be_nil
  end
end

describe "Anthropic and thinking" do
  it "asks for it only when an effort is set" do
    probe = ProbeAnthropic.new(api_key: "k")

    probe.payload_for(request_with([] of Smith::LLM::ContentBlock))["thinking"]?.should be_nil

    payload = probe.payload_for(request_with([] of Smith::LLM::ContentBlock, thinking_effort: "medium"))
    payload["thinking"]["type"].as_s.should eq("adaptive")
    payload["output_config"]["effort"].as_s.should eq("medium")
  end

  it "asks for a summary, or the blocks would come back empty" do
    # display defaults to "omitted" on current models: thinking still happens
    # and is still billed, but there is nothing to show.
    payload = ProbeAnthropic.new(api_key: "k")
      .payload_for(request_with([] of Smith::LLM::ContentBlock, thinking_effort: "high"))

    payload["thinking"]["display"].as_s.should eq("summarized")
  end

  it "falls back to the token-budget form for pre-4.6 models" do
    payload = ProbeAnthropic.new(api_key: "k").payload_for(
      request_with([] of Smith::LLM::ContentBlock, thinking_effort: "medium", thinking_budget: 4000, max_tokens: 8000)
    )

    payload["thinking"]["type"].as_s.should eq("enabled")
    payload["thinking"]["budget_tokens"].as_i.should eq(4000)
    # Current models reject the two together.
    payload["output_config"]?.should be_nil
  end

  it "sends the block back with its signature byte for byte" do
    # Anthropic rejects the next request if the signature is altered, so this
    # is correctness, not cosmetics.
    payload = ProbeAnthropic.new(api_key: "k").payload_for(request_with([
      thinking_block,
      Smith::LLM::ContentBlock.tool_use("c1", "read_file", JSON.parse(%({"path": "a"}))),
    ]))

    block = payload["messages"].as_a.last["content"].as_a.first
    block["type"].as_s.should eq("thinking")
    block["thinking"].as_s.should eq("Let me think.")
    block["signature"].as_s.should eq(SIGNATURE)
  end

  it "sends redacted thinking back as opaque data" do
    payload = ProbeAnthropic.new(api_key: "k").payload_for(request_with([
      Smith::LLM::ContentBlock.redacted_thinking("EncryptedPayload=="),
    ]))

    block = payload["messages"].as_a.last["content"].as_a.first
    block["type"].as_s.should eq("redacted_thinking")
    block["data"].as_s.should eq("EncryptedPayload==")
  end

  it "parses both kinds out of a response" do
    response = ProbeAnthropic.new(api_key: "k").parse(<<-JSON)
      {"id":"m","model":"claude-sonnet-5","content":[
        {"type":"thinking","thinking":"step one","signature":"#{SIGNATURE}"},
        {"type":"redacted_thinking","data":"Enc=="},
        {"type":"text","text":"the answer"}
      ]}
      JSON

    response.content.size.should eq(3)
    response.content[0].type.thinking?.should be_true
    response.content[0].signature.should eq(SIGNATURE)
    response.content[1].type.redacted_thinking?.should be_true
    response.content[2].text.should eq("the answer")
  end

  it "refuses a budget that does not leave room to answer" do
    # The provider's own error for this is opaque; catching it here is clearer.
    expect_raises(ArgumentError, /budget/) do
      ProbeAnthropic.new(api_key: "k").payload_for(
        request_with([] of Smith::LLM::ContentBlock, thinking_budget: 8000, max_tokens: 4000)
      )
    end
  end
end

private class ProbeOllama < Smith::LLM::Ollama
  def payload_for(request : Smith::LLM::Request) : JSON::Any
    JSON.parse(build_payload("m", request))
  end
end

describe "other providers and thinking" do
  it "never sends thinking blocks to an OpenAI-shaped endpoint" do
    # They mean nothing there, and the signature is Anthropic's business.
    payload = ProbeOllama.new.payload_for(
      request_with([thinking_block, Smith::LLM::ContentBlock.text("answer")])
    )

    content = payload["messages"].as_a.last["content"].as_s
    content.should eq("answer")
    content.should_not contain("Let me think")
  end
end

describe "the Anthropic thinking stream" do
  it "assembles thinking text and its signature" do
    sse = <<-SSE
    data: {"type":"message_start","message":{"id":"m","model":"claude-sonnet-5"}}

    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"first "}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"second"}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"#{SIGNATURE}"}}

    data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"answer"}}

    data: [DONE]

    SSE

    response = Smith::LLM::AnthropicStream.read(IO::Memory.new(sse), "m") { |_| }

    thinking = response.content.first
    thinking.type.thinking?.should be_true
    thinking.text.should eq("first second")
    thinking.signature.should eq(SIGNATURE)
    response.content.last.text.should eq("answer")
  end

  it "does not send thinking through the text callback" do
    sse = <<-SSE
    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"private"}}

    data: [DONE]

    SSE

    printed = [] of String
    Smith::LLM::AnthropicStream.read(IO::Memory.new(sse), "m") { |chunk| printed << chunk }

    # Thinking has its own event so consumers listening for the answer are
    # unaffected.
    printed.should be_empty
  end
end

describe "thinking and context compaction" do
  it "counts toward the size estimate" do
    # Thinking blocks are bulky; ignoring them would make smith underestimate
    # the transcript and run into the context limit despite compaction.
    without = [Smith::LLM::Message.assistant_with_blocks([Smith::LLM::ContentBlock.text("short")])]
    including = [Smith::LLM::Message.assistant_with_blocks([
      Smith::LLM::ContentBlock.text("short"),
      thinking_block("a very long chain of reasoning " * 50),
    ])]

    Smith::Context.estimate_tokens(including).should be > Smith::Context.estimate_tokens(without) * 5
  end
end
