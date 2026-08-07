require "../../spec_helper"
require "../../../src/smith/llm/sse"

private def stream(*lines : String) : IO::Memory
  IO::Memory.new(lines.join("\n") + "\n")
end

private def read(io : IO) : Tuple(Smith::LLM::Response, Array(String))
  deltas = [] of String
  response = Smith::LLM::OpenAIStream.read(io, "fallback-model") { |chunk| deltas << chunk }
  {response, deltas}
end

describe Smith::LLM::SSE do
  it "yields the payload of every data line and stops at [DONE]" do
    payloads = [] of String

    Smith::LLM::SSE.each_data(stream(
      "data: one",
      "",
      "data: two",
      "data: [DONE]",
      "data: never-reached"
    )) { |payload| payloads << payload }

    payloads.should eq(["one", "two"])
  end

  it "ignores comments, blank lines and non-data fields" do
    payloads = [] of String

    Smith::LLM::SSE.each_data(stream(
      ": keep-alive comment",
      "",
      "event: message",
      "data: actual"
    )) { |payload| payloads << payload }

    payloads.should eq(["actual"])
  end
end

describe Smith::LLM::OpenAIStream do
  it "delivers text deltas in order and assembles the full text" do
    response, deltas = read(stream(
      %({"id":"gen-1","model":"m","choices":[{"delta":{"content":"Hello"}}]}).sub("data", "data"),
      %(data: {"id":"gen-1","model":"m","choices":[{"delta":{"content":" world"}}]}),
      %(data: {"choices":[{"delta":{},"finish_reason":"stop"}]}),
      "data: [DONE]"
    ))

    # The first line above is intentionally not a data: line and must be ignored.
    deltas.should eq([" world"])
    response.content.first.text.should eq(" world")
    response.stop_reason.should eq("stop")
  end

  it "reassembles tool arguments split across chunks" do
    # The case a naive implementation gets wrong: `arguments` arrives as
    # fragments that are only valid JSON once the last one lands.
    response, deltas = read(stream(
      %(data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash","arguments":""}}]}}]}),
      %(data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"comm"}}]}}]}),
      %(data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"and\\": \\"ls -la\\"}"}}]}}]}),
      "data: [DONE]"
    ))

    deltas.should be_empty

    block = response.content.first
    block.type.tool_use?.should be_true
    block.tool_call_id.should eq("call_1")
    block.tool_name.should eq("bash")
    block.tool_args.not_nil!["command"].as_s.should eq("ls -la")
  end

  it "keeps parallel tool calls apart by index" do
    response, _ = read(stream(
      %(data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"read_file","arguments":"{\\"path\\":"}}]}}]}),
      %(data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"grep","arguments":"{\\"pattern\\":"}}]}}]}),
      %(data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"a.txt\\"}"}}]}}]}),
      %(data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"\\"TODO\\"}"}}]}}]}),
      "data: [DONE]"
    ))

    response.content.size.should eq(2)

    first, second = response.content
    first.tool_name.should eq("read_file")
    first.tool_args.not_nil!["path"].as_s.should eq("a.txt")
    second.tool_name.should eq("grep")
    second.tool_args.not_nil!["pattern"].as_s.should eq("TODO")
  end

  it "picks up usage when the provider sends it" do
    response, _ = read(stream(
      %(data: {"choices":[{"delta":{"content":"hi"}}]}),
      %(data: {"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":4,"total_tokens":15}}),
      "data: [DONE]"
    ))

    response.usage.not_nil!.prompt_tokens.should eq(11)
    response.usage.not_nil!.total_tokens.should eq(15)
  end

  it "leaves usage nil when the provider omits it" do
    response, _ = read(stream(
      %(data: {"choices":[{"delta":{"content":"hi"}}]}),
      "data: [DONE]"
    ))

    response.usage.should be_nil
  end

  it "survives a malformed frame mid-stream" do
    response, deltas = read(stream(
      %(data: {"choices":[{"delta":{"content":"before"}}]}),
      "data: {this is not json",
      %(data: {"choices":[{"delta":{"content":" after"}}]}),
      "data: [DONE]"
    ))

    deltas.should eq(["before", " after"])
    response.content.first.text.should eq("before after")
  end

  it "falls back to the default model when the stream omits one" do
    response, _ = read(stream(
      %(data: {"choices":[{"delta":{"content":"hi"}}]}),
      "data: [DONE]"
    ))

    response.model.should eq("fallback-model")
  end

  it "ends cleanly when the stream stops without [DONE]" do
    response, deltas = read(stream(
      %(data: {"choices":[{"delta":{"content":"truncated"}}]})
    ))

    deltas.should eq(["truncated"])
    response.content.first.text.should eq("truncated")
  end
end
