require "../../spec_helper"
require "../../../src/smith/llm/anthropic_stream"

private def stream(*lines : String) : IO::Memory
  IO::Memory.new(lines.join("\n") + "\n")
end

private def read(io : IO) : Tuple(Smith::LLM::Response, Array(String))
  deltas = [] of String
  response = Smith::LLM::AnthropicStream.read(io, "fallback-model") { |chunk| deltas << chunk }
  {response, deltas}
end

describe Smith::LLM::AnthropicStream do
  it "assembles text from content_block_delta events" do
    response, deltas = read(stream(
      %(data: {"type":"message_start","message":{"id":"msg_1","model":"claude-sonnet-5","usage":{"input_tokens":9}}}),
      %(data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}),
      %(data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}),
      %(data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" there"}}),
      %(data: {"type":"content_block_stop","index":0}),
      %(data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":4}}),
      %(data: {"type":"message_stop})
    ))

    deltas.should eq(["Hello", " there"])
    response.id.should eq("msg_1")
    response.model.should eq("claude-sonnet-5")
    response.content.first.text.should eq("Hello there")
    response.stop_reason.should eq("end_turn")
    response.usage.not_nil!.prompt_tokens.should eq(9)
    response.usage.not_nil!.completion_tokens.should eq(4)
    response.usage.not_nil!.total_tokens.should eq(13)
  end

  it "reassembles tool input from input_json_delta fragments" do
    response, deltas = read(stream(
      %(data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"bash"}}),
      %(data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"comm"}}),
      %(data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"and\\": \\"ls\\"}"}}),
      %(data: {"type":"content_block_stop","index":0})
    ))

    # Tool arguments are not assistant text, so nothing is streamed to screen.
    deltas.should be_empty

    block = response.content.first
    block.type.tool_use?.should be_true
    block.tool_call_id.should eq("toolu_1")
    block.tool_name.should eq("bash")
    block.tool_args.not_nil!["command"].as_s.should eq("ls")
  end

  it "handles a text block followed by a tool_use block" do
    response, deltas = read(stream(
      %(data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}),
      %(data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Let me look."}}),
      %(data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_2","name":"read_file"}}),
      %(data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\":\\"a.txt\\"}"}}),
      %(data: {"type":"content_block_stop","index":1})
    ))

    deltas.should eq(["Let me look."])
    response.content.size.should eq(2)
    response.content[0].type.text?.should be_true
    response.content[1].tool_name.should eq("read_file")
  end

  it "survives a malformed frame mid-stream" do
    response, deltas = read(stream(
      %(data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"before"}}),
      "data: {broken",
      %(data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" after"}})
    ))

    deltas.should eq(["before", " after"])
    response.content.first.text.should eq("before after")
  end

  it "leaves usage nil when no token counts arrive" do
    response, _ = read(stream(
      %(data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}})
    ))

    response.usage.should be_nil
  end
end
