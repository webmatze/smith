require "../spec_helper"
require "../../src/smith/plan"
require "../../src/smith/subagents"
require "../../src/smith/tools/exit_plan_mode"

# Records the tool specs it was offered, which is how the specs below see what
# a child registry actually contains without reaching into private methods.
private class ToolSpyProvider < Smith::LLM::Provider
  getter offered = Array(Array(String)).new

  def name : String
    "mock"
  end

  def default_model : String
    "mock-model"
  end

  def complete(request : Smith::LLM::Request) : Smith::LLM::Response
    @offered << (request.tools || Array(Smith::LLM::ToolSpec).new).map(&.name)
    Smith::LLM::Response.new("resp", request.model, [Smith::LLM::ContentBlock.text("done")])
  end
end

# Always asks to exit plan mode, so the halt path can be observed.
private class ExitPlanProvider < Smith::LLM::Provider
  getter calls = 0

  def name : String
    "mock"
  end

  def default_model : String
    "mock-model"
  end

  def complete(request : Smith::LLM::Request) : Smith::LLM::Response
    @calls += 1

    blocks = if @calls == 1
               [Smith::LLM::ContentBlock.tool_use("call_1", "exit_plan_mode", JSON.parse(%({"plan": "do it"})))]
             else
               [Smith::LLM::ContentBlock.text("Implemented.")]
             end

    Smith::LLM::Response.new("resp", request.model, blocks)
  end
end

describe "subagents in plan mode" do
  it "forces every child into inspect mode, so plan mode cannot be delegated around" do
    provider = ToolSpyProvider.new
    supervisor = Smith::Subagents::Supervisor.new
    supervisor.plan_mode = true

    supervisor.run_child(
      prompt: "Change all the things",
      mode: Smith::Subagents::Mode::Work,
      provider: provider,
      model: "mock-model"
    )

    tools = provider.offered.first
    tools.should contain("read_file")
    tools.should_not contain("bash")
    tools.should_not contain("write_file")
    tools.should_not contain("edit_file")
  end

  it "still honours work mode outside plan mode" do
    provider = ToolSpyProvider.new
    supervisor = Smith::Subagents::Supervisor.new

    supervisor.run_child(
      prompt: "Change all the things",
      mode: Smith::Subagents::Mode::Work,
      provider: provider,
      model: "mock-model"
    )

    provider.offered.first.should contain("bash")
  end
end

describe "the agent loop in plan mode" do
  it "stops after an unapproved plan instead of carrying on" do
    provider = ExitPlanProvider.new
    session = Smith::PlanSession.new(Smith::Mode::Plan, Smith::HaltingPlanGate.new)

    registry = Smith::Tools::Registry.default(Smith::Tools::PlanApprover.new)
    registry.register(Smith::Tools::ExitPlanMode.new(session))

    agent = Smith::Agent.new(provider: provider, registry: registry, model: "mock-model")
    session.on_halt = -> { agent.stop!; nil }

    completed = 0
    agent.on_event do |event|
      completed += 1 if event.is_a?(Smith::Events::TurnCompleted)
    end

    agent.send("Add a feature")

    # Without the halt the loop would go on to a second provider call.
    provider.calls.should eq(1)
    completed.should eq(1)
    session.plan_mode?.should be_true
  end

  it "keeps running once the plan was approved" do
    provider = ExitPlanProvider.new
    session = Smith::PlanSession.new(Smith::Mode::Plan, Smith::AutoPlanGate.new)

    registry = Smith::Tools::Registry.default(Smith::Tools::PlanApprover.new)
    registry.register(Smith::Tools::ExitPlanMode.new(session))

    agent = Smith::Agent.new(provider: provider, registry: registry, model: "mock-model")
    session.on_halt = -> { agent.stop!; nil }
    session.on_mode_change = ->(mode : Smith::Mode) do
      registry.approver = Smith::Tools::AutoApprover.new if mode.normal?
      nil
    end

    agent.send("Add a feature")

    provider.calls.should eq(2)
    session.plan_mode?.should be_false
  end
end

describe "plan mode configuration" do
  it "defaults to normal mode" do
    Smith::Config.new.mode.should eq(Smith::Mode::Normal)
  end

  it "reads [defaults] mode from the config file" do
    Smith::Config.new(TOML.parse(%(
      [defaults]
      mode = "plan"
    ))).mode.should eq(Smith::Mode::Plan)
  end

  it "lets SMITH_MODE win over the config file" do
    ENV["SMITH_MODE"] = "plan"
    begin
      Smith::Config.new.mode.should eq(Smith::Mode::Plan)
    ensure
      ENV.delete("SMITH_MODE")
    end
  end
end
