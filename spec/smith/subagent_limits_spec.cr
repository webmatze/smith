require "../spec_helper"
require "../../src/smith/subagents"

private class QuietProvider < Smith::LLM::Provider
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

private def run(supervisor : Smith::Subagents::Supervisor, provider = QuietProvider.new)
  supervisor.run_child(
    prompt: "do a thing",
    mode: Smith::Subagents::Mode::Inspect,
    provider: provider,
    model: "mock-model"
  )
end

describe Smith::Subagents::SpawnBudget do
  it "hands out exactly as many spawns as it was given" do
    budget = Smith::Subagents::SpawnBudget.new(2)

    budget.claim?.should be_true
    budget.claim?.should be_true
    budget.claim?.should be_false
    budget.remaining.should eq(0)
  end

  it "is empty from the start when the limit is zero" do
    Smith::Subagents::SpawnBudget.new(0).claim?.should be_false
  end
end

describe "subagent depth" do
  it "spawns happily below the limit" do
    (0...Smith::Subagents::Supervisor::MAX_DEPTH).each do |depth|
      report = run(Smith::Subagents::Supervisor.new(depth: depth))
      report.status.should eq("completed"), "depth #{depth} was rejected"
    end
  end

  it "refuses to go deeper than the limit" do
    report = run(Smith::Subagents::Supervisor.new(depth: Smith::Subagents::Supervisor::MAX_DEPTH))

    report.status.should eq("rejected")
    report.summary.should contain("nesting limit")
    # The model has to see the blockage in the transcript and pick another
    # route, exactly as it does for the width cap.
    report.summary.should contain("directly")
  end

  it "honours a configured depth" do
    run(Smith::Subagents::Supervisor.new(max_depth: 1, depth: 0)).status.should eq("completed")
    run(Smith::Subagents::Supervisor.new(max_depth: 1, depth: 1)).status.should eq("rejected")
  end

  it "hands children a supervisor one level deeper" do
    parent = Smith::Subagents::Supervisor.new
    child = parent.child_supervisor("1")

    child.depth.should eq(parent.depth + 1)
  end
end

describe "the spawn budget across levels" do
  it "is shared, not restarted per level" do
    budget = Smith::Subagents::SpawnBudget.new(3)
    parent = Smith::Subagents::Supervisor.new(budget: budget)
    child = parent.child_supervisor("1")

    run(parent).status.should eq("completed")
    run(parent).status.should eq("completed")
    run(child).status.should eq("completed")

    # Three spawned in total — the nested supervisor draws from the same pot.
    run(child).status.should eq("rejected")
    run(parent).status.should eq("rejected")
  end

  it "explains the exhausted budget to the model" do
    supervisor = Smith::Subagents::Supervisor.new(budget: Smith::Subagents::SpawnBudget.new(1))
    run(supervisor)

    report = run(supervisor)
    report.status.should eq("rejected")
    report.summary.should contain("subagents")
  end

  it "refuses everything when the budget is zero" do
    run(Smith::Subagents::Supervisor.new(budget: Smith::Subagents::SpawnBudget.new(0)))
      .status.should eq("rejected")
  end
end

describe "subagent node ids" do
  it "numbers siblings in order" do
    supervisor = Smith::Subagents::Supervisor.new

    run(supervisor).node_id.should eq("subagent-1")
    run(supervisor).node_id.should eq("subagent-2")
  end

  it "nests the path, so an id is unambiguous across levels" do
    parent = Smith::Subagents::Supervisor.new
    run(parent)
    second = run(parent)

    grandchild = parent.child_supervisor(second.node_id.lchop("subagent-"))
    run(grandchild).node_id.should eq("subagent-2.1")
    run(grandchild.child_supervisor("2.1")).node_id.should eq("subagent-2.1.1")
  end
end

describe "the child registry" do
  # The tripwire this issue exists for. Nesting is currently impossible only
  # because nobody registered the agent tool for children — an invariant with
  # no test behind it. If you deliberately add it (see #21), pass
  # child_supervisor so depth and budget apply, and add a nesting test here.
  it "does not hand children the agent tool" do
    provider = QuietProvider.new
    run(Smith::Subagents::Supervisor.new, provider)

    provider.offered.first.should_not contain("agent")
  end
end

describe "subagent configuration" do
  it "defaults to three levels and twenty children" do
    config = Smith::Config.new

    config.subagents.max_depth.should eq(3)
    config.subagents.max_children.should eq(20)
  end

  it "reads both limits from the config file" do
    config = Smith::Config.new(TOML.parse(%(
      [subagents]
      max_depth = 1
      max_children = 5
    )))

    config.subagents.max_depth.should eq(1)
    config.subagents.max_children.should eq(5)
  end
end
