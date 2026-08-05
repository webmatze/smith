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
