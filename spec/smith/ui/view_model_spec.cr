require "../../spec_helper"
require "../../../src/smith/ui/view_model"

include Smith::UI

private def plain_lines(lines : Array(Smith::UI::StyledLine)) : Array(String)
  lines.map { |l| Smith::UI::LineUtil.plain(l) }
end

describe Smith::UI::UserBlock do
  it "prefixes the first line with the prompt glyph" do
    lines = UserBlock.new("hello").lines(40)
    plain_lines(lines)[0].should start_with("❯ hello")
  end

  it "indents continuation lines" do
    lines = UserBlock.new(("word " * 30).strip).lines(20)
    plain_lines(lines).size.should be > 1
    plain_lines(lines)[1].should start_with("  ")
  end

  it "renders an empty prompt as one line" do
    lines = UserBlock.new("").lines(40)
    lines.size.should eq(1)
  end
end

describe Smith::UI::AssistantBlock do
  it "shows a live cursor while streaming" do
    block = AssistantBlock.new("hi", live: true)
    plain = plain_lines(block.lines(40)).join
    plain.should contain("▊")
  end

  it "drops the cursor once finished" do
    block = AssistantBlock.new("hi", live: false)
    plain = plain_lines(block.lines(40)).join
    plain.should_not contain("▊")
  end

  it "never renders zero lines" do
    block = AssistantBlock.new("", live: false)
    block.lines(40).size.should be >= 1
  end

  it "renders its buffer as markdown" do
    block = AssistantBlock.new("## Title", live: false)
    plain = plain_lines(block.lines(40)).join
    plain.should contain("Title")
    plain.should_not contain("##")
  end
end

describe Smith::UI::ThinkingBlock do
  it "shows the buffer with a marker while live" do
    block = ThinkingBlock.new(buffer: "reasoning")
    plain = plain_lines(block.lines(40)).join
    plain.should contain("✻")
    plain.should contain("reasoning")
  end

  it "collapses to a duration once finished" do
    block = ThinkingBlock.new(buffer: "reasoning", live: false)
    plain = plain_lines(block.lines(40)).join
    plain.should contain("Thinking")
    plain.should_not contain("reasoning")
  end
end

describe Smith::UI::ToolBlock do
  it "summarizes the first recognizable argument" do
    ToolBlock.summarize(JSON.parse(%({"command": "ls -la"}))).should eq("ls -la")
    ToolBlock.summarize(JSON.parse(%({"path": "/tmp/x"}))).should eq("/tmp/x")
    ToolBlock.summarize(JSON.parse(%({"url": "https://a.b"}))).should eq("https://a.b")
  end

  it "falls back to truncated JSON" do
    ToolBlock.summarize(JSON.parse(%({"other": 1}))).should eq(%({"other":1}))
  end

  it "collapses whitespace in the summary" do
    ToolBlock.summarize(JSON.parse(%({"command": "echo   a\\nb"}))).should eq("echo a b")
  end

  it "shows a check mark when done" do
    block = ToolBlock.new("id", "bash", "ls", status: ToolBlock::Status::Done)
    plain = plain_lines(block.lines(60)).join
    plain.should contain("✓")
    plain.should contain("bash")
  end

  it "shows a cross and the first error lines when failed" do
    block = ToolBlock.new("id", "bash", "ls", status: ToolBlock::Status::Failed, result: "boom\ndetails")
    plain = plain_lines(block.lines(60)).join("\n")
    plain.should contain("✗")
    plain.should contain("boom")
  end

  it "shows a spinner while running" do
    block = ToolBlock.new("id", "bash", "ls")
    plain = plain_lines(block.lines(60)).join
    plain.should contain(Smith::UI::Spinner.frame)
  end
end

describe Smith::UI::TodosBlock do
  it "shows a done/total counter and status marks" do
    items = [
      Smith::TodoList::Item.new("one", Smith::TodoList::Status::Completed),
      Smith::TodoList::Item.new("two", Smith::TodoList::Status::InProgress),
      Smith::TodoList::Item.new("three", Smith::TodoList::Status::Pending),
    ]
    lines = TodosBlock.new(items).lines(40)
    plain = plain_lines(lines)

    plain[0].should contain("1/3")
    plain[1].should start_with("☑")
    plain[2].should start_with("▶")
    plain[3].should start_with("☐")
  end
end

describe Smith::UI::NoticeBlock do
  it "wraps long notices to the width" do
    block = NoticeBlock.text("the quick brown fox", Style::NONE)
    lines = block.lines(10)
    lines.each { |l| Smith::UI::LineUtil.width(l).should be <= 10 }
  end
end

describe Smith::UI::Spinner do
  it "cycles through its frames over time" do
    a = Spinner.frame(0_i64)
    b = Spinner.frame(160_i64)
    Spinner::FRAMES.should contain(a)
    Spinner::FRAMES.should contain(b)
    a.should_not eq(b)
  end

  it "handles negative clocks" do
    Spinner.frame(-80_i64).should be_a(String)
  end
end
