require "../../spec_helper"
require "../../../src/smith/tools/exit_plan_mode"

describe Smith::Tools::ExitPlanMode do
  it "hands the plan to the session and returns its verdict" do
    session = Smith::PlanSession.new(Smith::Mode::Plan, Smith::AutoPlanGate.new)
    tool = Smith::Tools::ExitPlanMode.new(session)

    result = tool.run(JSON.parse({"plan" => "1. Read\n2. Patch"}.to_json))

    result.should eq("Plan approved. Proceed with implementation.")
    session.plan_mode?.should be_false
  end

  it "returns a clean error string when the plan is missing" do
    tool = Smith::Tools::ExitPlanMode.new(Smith::PlanSession.new(Smith::Mode::Plan))

    tool.run(JSON.parse(%({}))).should start_with("Error:")
  end

  it "is neither parallel-safe nor mutating" do
    tool = Smith::Tools::ExitPlanMode.new(Smith::PlanSession.new)

    tool.parallel?.should be_false
    # Mutating would route it through the approval gate — which in plan mode is
    # the PlanApprover, so the only way out of plan mode would be blocked.
    tool.mutating?.should be_false
  end
end

describe "Smith::Tools::Registry#unregister" do
  it "removes a tool from execution and from the advertised specs" do
    registry = Smith::Tools::Registry.default

    registry.unregister("glob").should be_true
    registry.get("glob").should be_nil
    registry.specs.map(&.name).should_not contain("glob")

    result = registry.execute_calls([
      Smith::Tools::CallRequest.new("1", "glob", JSON.parse(%({"pattern": "*"}))),
    ]).first
    result.is_error.should be_true
  end

  it "reports when there was nothing to remove" do
    Smith::Tools::Registry.default.unregister("nope").should be_false
  end
end
