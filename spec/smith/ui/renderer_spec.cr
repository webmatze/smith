require "./support/scripted_io"

include Smith::UI

private def tool_args(json : String = %({"command": "ls -la"})) : JSON::Any
  JSON.parse(json)
end

describe Smith::UI::NoticeIO do
  it "turns complete lines into notices" do
    app = app_with
    io = NoticeIO.new(app)
    io.print "hello\n"
    io.flush

    app.blocks.size.should eq(1)
    app.blocks[0].should be_a(NoticeBlock)
  end

  it "buffers partial lines until the newline arrives" do
    app = app_with
    io = NoticeIO.new(app)
    io.print "part "
    app.blocks.size.should eq(0)

    io.print "two\n"
    app.blocks.size.should eq(1)
  end

  it "skips blank lines" do
    app = app_with
    io = NoticeIO.new(app)
    io.print "   \n\nreal\n"
    app.blocks.size.should eq(1)
  end

  it "is write-only" do
    app = app_with
    io = NoticeIO.new(app)
    expect_raises(IO::Error) { io.read(Bytes.new(1)) }
  end
end

describe Smith::UI::TuiRenderer do
  it "accumulates assistant deltas into one live block" do
    app = app_with
    renderer = TuiRenderer.new(app)

    renderer.handle(Smith::Events::AssistantTextDelta.new("Hel"))
    renderer.handle(Smith::Events::AssistantTextDelta.new("lo"))

    app.blocks.size.should eq(1)
    block = app.blocks[0].as(AssistantBlock)
    block.buffer.should eq("Hello")
    block.live?.should be_true

    renderer.handle(Smith::Events::AssistantText.new("Hello"))
    block.live?.should be_false
    renderer.answer.should eq("Hello")
  end

  it "opens a fresh assistant block after a tool ran" do
    app = app_with
    renderer = TuiRenderer.new(app)

    renderer.handle(Smith::Events::AssistantTextDelta.new("before"))
    renderer.handle(Smith::Events::ToolStart.new("t1", "bash", tool_args))
    renderer.handle(Smith::Events::ToolFinished.new("t1", "bash", "ok", false))
    renderer.handle(Smith::Events::AssistantTextDelta.new("after"))

    app.blocks.map(&.class).should eq([AssistantBlock, ToolBlock, AssistantBlock])
    app.blocks[2].as(AssistantBlock).buffer.should eq("after")
  end

  it "marks tools done or failed on ToolFinished" do
    app = app_with
    renderer = TuiRenderer.new(app)

    renderer.handle(Smith::Events::ToolStart.new("t1", "bash", tool_args))
    renderer.handle(Smith::Events::ToolStart.new("t2", "bash", tool_args))
    renderer.handle(Smith::Events::ToolFinished.new("t1", "bash", "ok", false))
    renderer.handle(Smith::Events::ToolFinished.new("t2", "bash", "boom", true))

    blocks = app.blocks.select(ToolBlock)
    blocks[0].status.done?.should be_true
    blocks[1].status.failed?.should be_true
    blocks[1].result.should eq("boom")
  end

  it "keeps running tools live and finished ones finalized" do
    app = app_with
    renderer = TuiRenderer.new(app)

    renderer.handle(Smith::Events::ToolStart.new("t1", "bash", tool_args))
    renderer.handle(Smith::Events::ToolFinished.new("t1", "bash", "ok", false))

    # Finalization happens on the next flush, so ask for it.
    app.flush_blocks!
    app.blocks.size.should eq(1)
  end

  it "renders todos updates as a block" do
    app = app_with
    renderer = TuiRenderer.new(app)
    items = [Smith::TodoList::Item.new("a", Smith::TodoList::Status::Pending)]

    renderer.handle(Smith::Events::TodosUpdated.new(items))
    app.blocks[0].should be_a(TodosBlock)
  end

  it "notices a cleared todo list instead of drawing nothing" do
    app = app_with
    renderer = TuiRenderer.new(app)

    renderer.handle(Smith::Events::TodosUpdated.new([] of Smith::TodoList::Item))
    app.blocks[0].should be_a(NoticeBlock)
  end

  it "tracks the plan mode in the app" do
    app = app_with
    renderer = TuiRenderer.new(app)

    renderer.handle(Smith::Events::ModeChanged.new(Smith::Mode::Plan))
    app.mode.plan?.should be_true

    renderer.handle(Smith::Events::ModeChanged.new(Smith::Mode::Normal))
    app.mode.normal?.should be_true
  end

  it "shows thinking deltas separately from the answer" do
    app = app_with
    renderer = TuiRenderer.new(app)

    renderer.handle(Smith::Events::ThinkingDelta.new("hm"))
    renderer.handle(Smith::Events::ThinkingBlock.new("hm"))

    app.blocks.size.should eq(1)
    block = app.blocks[0].as(ThinkingBlock)
    block.live?.should be_false
  end

  it "marks a redacted thinking block with a notice" do
    app = app_with
    renderer = TuiRenderer.new(app)

    renderer.handle(Smith::Events::ThinkingBlock.new("", redacted: true))
    app.blocks.any?(NoticeBlock).should be_true
  end

  it "updates the usage line in the status bar" do
    app = app_with
    renderer = TuiRenderer.new(app)

    usage = Smith::LLM::Usage.new(900, 100, 1000)
    renderer.handle(Smith::Events::UsageUpdated.new(usage))
    app.usage_text.should eq("1000 tok")
  end

  it "formats large token counts compactly" do
    app = app_with
    renderer = TuiRenderer.new(app)

    renderer.handle(Smith::Events::UsageUpdated.new(Smith::LLM::Usage.new(0, 25_000, 25_000)))
    app.usage_text.should eq("25.0k tok")

    renderer.handle(Smith::Events::UsageUpdated.new(Smith::LLM::Usage.new(0, 1_500_000, 1_500_000)))
    app.usage_text.should eq("1.5M tok")
  end

  it "marks the run failed on TurnError" do
    app = app_with
    renderer = TuiRenderer.new(app)

    renderer.handle(Smith::Events::TurnError.new("boom"))
    renderer.failed?.should be_true
    renderer.exit_code.should eq(1)
  end

  it "marks the run budget-capped on BudgetExceeded" do
    app = app_with
    renderer = TuiRenderer.new(app)

    renderer.handle(Smith::Events::BudgetExceeded.new(1.2, 1.0))
    renderer.budget_exceeded?.should be_true
    renderer.exit_code.should eq(2)
  end

  it "prints the banner as notices" do
    app = app_with
    renderer = TuiRenderer.new(app)
    renderer.banner("anthropic", "claude", ["test", "deploy"])

    app.blocks.size.should eq(1)
    lines = app.blocks[0].lines(80).map { |l| LineUtil.plain(l) }
    lines.join("\n").should contain("smith")
    lines.join("\n").should contain("anthropic")
    lines.join("\n").should contain("skills: test, deploy")
  end

  it "summarizes usage on finish" do
    app = app_with
    renderer = TuiRenderer.new(app)
    usage = Smith::LLM::Usage.new(100, 50, 150, cache_read_tokens: 20)

    renderer.finish(usage, 0.05)
    app.blocks.size.should eq(1)
    text = app.blocks[0].lines(120).map { |l| LineUtil.plain(l) }.join
    text.should contain("100 tok prompt")
    text.should contain("(20 cached)")
  end

  it "routes prompt_io through the app" do
    app = app_with
    renderer = TuiRenderer.new(app)

    renderer.prompt_io.puts "warning: something"
    app.blocks.any?(NoticeBlock).should be_true
  end
end
