require "../spec_helper"
require "../../src/smith/plan"

private def bash_call
  Smith::Tools::CallRequest.new("1", "bash", JSON.parse(%({"command": "rm -rf /"})))
end

# Approves nothing and records what it was shown, so the specs can assert on
# the plan text without a terminal.
private class RecordingGate < Smith::PlanGate
  getter seen = [] of String

  def initialize(@verdict : Smith::PlanVerdict = Smith::PlanVerdict.approved)
  end

  def review(plan : String) : Smith::PlanVerdict
    @seen << plan
    @verdict
  end
end

describe Smith::Mode do
  it "parses the config/env spelling, defaulting to normal" do
    Smith::Mode.from_string("plan").should eq(Smith::Mode::Plan)
    Smith::Mode.from_string("  PLAN  ").should eq(Smith::Mode::Plan)
    Smith::Mode.from_string("normal").should eq(Smith::Mode::Normal)
    Smith::Mode.from_string("nonsense").should eq(Smith::Mode::Normal)
  end
end

describe Smith::Tools::PlanApprover do
  it "denies every mutating tool outright" do
    approver = Smith::Tools::PlanApprover.new

    approver.approve?(Smith::Tools::Bash.new, bash_call).should be_false
    approver.approve?(Smith::Tools::WriteFile.new, bash_call).should be_false
    approver.approve?(Smith::Tools::EditFile.new, bash_call).should be_false
  end

  it "explains the block so the model can route around it" do
    message = Smith::Tools::PlanApprover.new.denial_message(Smith::Tools::WriteFile.new, bash_call)

    message.should contain("write_file")
    message.should contain("plan mode")
    message.should contain("exit_plan_mode")
  end
end

describe "the registry approver swap" do
  it "gates and ungates execution without rebuilding the registry" do
    path = File.join(Dir.tempdir, "smith_plan_gate_#{Random::Secure.hex(4)}.txt")
    registry = Smith::Tools::Registry.default(Smith::Tools::PlanApprover.new)
    call = Smith::Tools::CallRequest.new("1", "write_file", JSON.parse({"path" => path, "content" => "x"}.to_json))

    begin
      blocked = registry.execute_calls([call]).first
      blocked.is_error.should be_true
      File.exists?(path).should be_false

      registry.approver = Smith::Tools::AutoApprover.new

      allowed = registry.execute_calls([call]).first
      allowed.is_error.should be_false
      File.exists?(path).should be_true
    ensure
      File.delete(path) if File.exists?(path)
    end
  end
end

describe Smith::PlanSession do
  it "starts in the mode it was given" do
    Smith::PlanSession.new.plan_mode?.should be_false
    Smith::PlanSession.new(Smith::Mode::Plan).plan_mode?.should be_true
  end

  it "shows the plan to the gate and announces it" do
    gate = RecordingGate.new
    session = Smith::PlanSession.new(Smith::Mode::Plan, gate)
    announced = [] of String
    session.on_plan = ->(plan : String) { announced << plan; nil }

    session.present("1. Read the file\n2. Patch it")

    gate.seen.should eq(["1. Read the file\n2. Patch it"])
    announced.should eq(["1. Read the file\n2. Patch it"])
  end

  it "leaves plan mode when the plan is approved" do
    session = Smith::PlanSession.new(Smith::Mode::Plan, RecordingGate.new(Smith::PlanVerdict.approved))
    modes = [] of Smith::Mode
    session.on_mode_change = ->(mode : Smith::Mode) { modes << mode; nil }

    result = session.present("do the thing")

    session.plan_mode?.should be_false
    modes.should eq([Smith::Mode::Normal])
    result.should eq("Plan approved. Proceed with implementation.")
  end

  it "stays in plan mode and hands the feedback back when rejected" do
    session = Smith::PlanSession.new(Smith::Mode::Plan, RecordingGate.new(Smith::PlanVerdict.rejected("touch fewer files")))
    halted = false
    session.on_halt = -> { halted = true; nil }

    result = session.present("do the thing")

    session.plan_mode?.should be_true
    result.should eq("Plan rejected. User feedback: touch fewer files")
    halted.should be_false
  end

  it "halts the run instead of proceeding when there is nobody to approve" do
    session = Smith::PlanSession.new(Smith::Mode::Plan, RecordingGate.new(Smith::PlanVerdict.halted))
    halted = false
    session.on_halt = -> { halted = true; nil }

    result = session.present("do the thing")

    halted.should be_true
    session.plan_mode?.should be_true
    result.should contain("without making changes")
  end

  it "switches modes explicitly for /plan and /normal" do
    session = Smith::PlanSession.new
    modes = [] of Smith::Mode
    session.on_mode_change = ->(mode : Smith::Mode) { modes << mode; nil }

    session.mode = Smith::Mode::Plan
    session.mode = Smith::Mode::Plan # already there — no second announcement
    session.mode = Smith::Mode::Normal

    modes.should eq([Smith::Mode::Plan, Smith::Mode::Normal])
  end
end

describe Smith::PlanGate do
  it "approves without asking under --yes" do
    Smith::AutoPlanGate.new.review("plan").decision.should eq(Smith::PlanDecision::Approved)
  end

  it "halts rather than proceeding when nobody can be asked" do
    Smith::HaltingPlanGate.new.review("plan").decision.should eq(Smith::PlanDecision::Halted)
  end

  it "approves on y" do
    gate = Smith::PromptPlanGate.new(IO::Memory.new("y\n"), IO::Memory.new)
    gate.review("plan").decision.should eq(Smith::PlanDecision::Approved)
  end

  it "collects free-text feedback on n" do
    gate = Smith::PromptPlanGate.new(IO::Memory.new("n\ntouch fewer files\n"), IO::Memory.new)

    verdict = gate.review("plan")
    verdict.decision.should eq(Smith::PlanDecision::Rejected)
    verdict.feedback.should eq("touch fewer files")
  end

  it "halts on q and on EOF" do
    Smith::PromptPlanGate.new(IO::Memory.new("q\n"), IO::Memory.new)
      .review("plan").decision.should eq(Smith::PlanDecision::Halted)
    Smith::PromptPlanGate.new(IO::Memory.new(""), IO::Memory.new)
      .review("plan").decision.should eq(Smith::PlanDecision::Halted)
  end

  it "re-asks on an unrecognised answer instead of guessing" do
    output = IO::Memory.new
    gate = Smith::PromptPlanGate.new(IO::Memory.new("maybe\ny\n"), output)

    gate.review("plan").decision.should eq(Smith::PlanDecision::Approved)
    output.to_s.should contain("y, n or q")
  end
end
