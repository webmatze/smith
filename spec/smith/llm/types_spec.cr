require "../../spec_helper"

describe Smith::LLM::ContentBlock do
  it "creates text blocks" do
    block = Smith::LLM::ContentBlock.text("Hello world")
    block.type.should eq(Smith::LLM::ContentBlock::BlockType::Text)
    block.text.should eq("Hello world")
  end

  it "creates tool use blocks" do
    args = JSON.parse(%({"path": "src/smith.cr"}))
    block = Smith::LLM::ContentBlock.tool_use("call_1", "read_file", args)
    block.type.should eq(Smith::LLM::ContentBlock::BlockType::ToolUse)
    block.tool_name.should eq("read_file")
    block.tool_call_id.should eq("call_1")
    block.tool_args.not_nil!["path"].as_s.should eq("src/smith.cr")
  end

  it "creates tool result blocks" do
    block = Smith::LLM::ContentBlock.tool_result("call_1", "file content", is_error: false)
    block.type.should eq(Smith::LLM::ContentBlock::BlockType::ToolResult)
    block.text.should eq("file content")
    block.is_error.should eq(false)
  end
end

describe Smith::LLM::Message do
  it "creates user messages" do
    msg = Smith::LLM::Message.user("Test prompt")
    msg.role.should eq(Smith::LLM::Role::User)
    msg.content.first.text.should eq("Test prompt")
  end
end

describe "how big the prompt actually was" do
  it "adds the cached parts back, which Anthropic reports separately" do
    # input_tokens on a cache hit is a few hundred tokens — the uncached
    # remainder, not the size of the request. Measuring context usage from it
    # would say a 100k-token history was 300 tokens.
    usage = Smith::LLM::Usage.new(
      300, 50, 350,
      cache_creation_tokens: 1_000,
      cache_read_tokens: 98_700
    )

    usage.billed_prompt_tokens.should eq(100_000)
  end

  it "is just the prompt tokens where nothing is cached" do
    Smith::LLM::Usage.new(1_200, 50, 1_250).billed_prompt_tokens.should eq(1_200)
  end
end

describe "message identity" do
  it "gives every message its own id" do
    a = Smith::LLM::Message.user("hello")
    b = Smith::LLM::Message.user("hello")

    a.id.should_not eq(b.id)
  end

  it "survives a round trip through JSON, which is what makes it an anchor" do
    message = Smith::LLM::Message.user("hello")

    Smith::LLM::Message.from_json(message.to_json).id.should eq(message.id)
  end

  it "gives a message saved before ids existed one on the way in" do
    # Checkpoints from that era point by index and keep working; anything taken
    # from here on points at these ids.
    legacy = %({"role":"user","content":[{"type":"text","text":"hi"}]})

    Smith::LLM::Message.from_json(legacy).id.should_not be_empty
  end
end
