require "./ui/support/screen"

# The two presentations answer the same questions with different objects.
# These specs pin that contract, since the CLI now trusts it instead of
# branching on a flag at every point of use.
describe Smith::PlainPresentation do
  it "builds the prompting gates and keeps their prompts off stdout" do
    stream = IO::Memory.new
    diagnostics = IO::Memory.new
    presentation = Smith::PlainPresentation.new(Smith::Output::JsonRenderer.new(stream, diagnostics))

    presentation.approver([] of String, Smith::Tools::RuleSet.new)
      .should be_a(Smith::Tools::PromptApprover)
    presentation.trust_prompt(Smith::TrustStore.new, preapproved: false)
      .should be_a(Smith::TrustPrompt)
    presentation.plan_gate.should be_a(Smith::PromptPlanGate)
    # In JSON mode a question on stdout would corrupt the stream mid-line.
    presentation.renderer.prompt_io.should eq(diagnostics)
  end

  it "indents an incidental line and leaves a laid-out block alone" do
    io = IO::Memory.new
    presentation = Smith::PlainPresentation.new(Smith::Output::HumanRenderer.new(io))

    presentation.say("stopping 1 job")
    presentation.say_block(["  Total", "  ─────"])

    io.to_s.should eq("   stopping 1 job\n  Total\n  ─────\n")
  end

  it "keeps incidental text out of the JSONL stream" do
    stream = IO::Memory.new
    diagnostics = IO::Memory.new
    presentation = Smith::PlainPresentation.new(Smith::Output::JsonRenderer.new(stream, diagnostics))

    presentation.say("stopping 1 job")
    presentation.say_block(["  Total"])

    # A line on stdout would land inside whatever record it interrupted.
    stream.to_s.should be_empty
    diagnostics.to_s.should eq("   stopping 1 job\n  Total\n")
  end

  it "sends diagnostics to stderr, where they have always gone" do
    presentation = Smith::PlainPresentation.new(Smith::Output::HumanRenderer.new(IO::Memory.new))
    presentation.notice_io.should eq(STDERR)
  end

  it "treats clear_screen as a no-op — plain output has no screen to wipe" do
    stream = IO::Memory.new
    presentation = Smith::PlainPresentation.new(Smith::Output::HumanRenderer.new(stream))

    presentation.clear_screen

    stream.to_s.should be_empty
  end
end

describe Smith::UI::TuiPresentation do
  it "builds the panel gates instead of the prompting ones" do
    presentation = Smith::UI::TuiPresentation.new(app_with)

    presentation.renderer.should be_a(Smith::UI::TuiRenderer)
    presentation.approver([] of String, Smith::Tools::RuleSet.new)
      .should be_a(Smith::UI::TuiApprover)
    presentation.trust_prompt(Smith::TrustStore.new, preapproved: false)
      .should be_a(Smith::UI::TuiTrustPrompt)
    presentation.plan_gate.should be_a(Smith::UI::TuiPlanGate)
    presentation.notice_io.should be_a(Smith::UI::NoticeIO)
  end

  it "turns said text into notice blocks on the app" do
    app = app_with
    presentation = Smith::UI::TuiPresentation.new(app)

    presentation.say("stopping 1 job")
    presentation.say_block(["Total", "─────"])

    app.blocks.size.should eq(2)
    # Notices arrive as written: a block is already set apart from its
    # surroundings, so there is nothing to indent it away from.
    Smith::UI::LineUtil.plain(app.blocks[0].lines(80)[0]).should eq("stopping 1 job")
    app.blocks[1].lines(80).map { |l| Smith::UI::LineUtil.plain(l) }.should eq(["Total", "─────"])
  end

  it "clears the app's blocks on clear_screen" do
    app = app_with
    presentation = Smith::UI::TuiPresentation.new(app)
    presentation.say("something")
    app.blocks.size.should eq(1)

    presentation.clear_screen

    app.blocks.should be_empty
  end
end
