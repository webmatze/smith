require "../spec_helper"
require "../../src/smith/subagents"
require "../../src/smith/tools/agent_tool"

class SubagentMockProvider < Smith::LLM::Provider
  def name : String
    "mock"
  end

  def default_model : String
    "mock-model"
  end

  def complete(request : Smith::LLM::Request) : Smith::LLM::Response
    blocks = [
      Smith::LLM::ContentBlock.text("Subagent finished subtask successfully.")
    ]
    Smith::LLM::Response.new("resp_sub", request.model, blocks, usage: Smith::LLM::Usage.new(5, 5, 10))
  end
end

describe Smith::Subagents::Supervisor do
  it "runs child subagents and returns execution reports" do
    provider = SubagentMockProvider.new
    supervisor = Smith::Subagents::Supervisor.new

    report = supervisor.run_child(
      prompt: "Research codebase files",
      mode: Smith::Subagents::Mode::Inspect,
      provider: provider,
      model: "qwen/qwen3.8-max"
    )

    report.node_id.should eq("subagent-1")
    report.status.should eq("completed")
    report.summary.should contain("Subagent finished subtask successfully.")
    report.usage.total_tokens.should eq(10)
  end

  it "executes AgentTool" do
    provider = SubagentMockProvider.new
    supervisor = Smith::Subagents::Supervisor.new
    agent_tool = Smith::Tools::AgentTool.new(supervisor: supervisor, provider: provider, model: "qwen/qwen3.8-max")

    output = agent_tool.run(JSON.parse(%({"prompt": "Do work", "mode": "work"})))
    output.should contain("Subagent [subagent-1] Report (completed)")
    output.should contain("Subagent finished subtask successfully.")
  end
end
