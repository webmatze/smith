require "../spec_helper"
require "../../src/smith/agents"

# Records what each child agent was actually given.
private class CaptureProvider < Smith::LLM::Provider
  getter systems = Array(String).new
  getter models = Array(String).new
  getter tools = Array(Array(String)).new

  def initialize(@label : String = "mock")
  end

  def name : String
    @label
  end

  def default_model : String
    "mock-model"
  end

  def complete(request : Smith::LLM::Request) : Smith::LLM::Response
    @systems << (request.system || "")
    @models << request.model
    @tools << (request.tools || Array(Smith::LLM::ToolSpec).new).map(&.name)

    Smith::LLM::Response.new("resp", request.model, [Smith::LLM::ContentBlock.text("done")])
  end
end

private def definition(
  name : String = "reviewer",
  tools : Array(String)? = nil,
  model : String? = nil,
  provider : String? = nil,
  mode : Smith::Subagents::Mode = Smith::Subagents::Mode::Work,
  system_prompt : String = "You are a reviewer.",
)
  Smith::Agents::Definition.new(
    name: name,
    description: "d",
    system_prompt: system_prompt,
    path: "/tmp/#{name}.md",
    tools: tools,
    model: model,
    provider: provider,
    mode: mode
  )
end

private def run(supervisor, provider, definition = nil, mode = Smith::Subagents::Mode::Work)
  supervisor.run_child(
    prompt: "do it",
    mode: mode,
    provider: provider,
    model: "parent-model",
    definition: definition
  )
end

describe "running a child from a definition" do
  it "uses the definition's system prompt" do
    provider = CaptureProvider.new
    run(Smith::Subagents::Supervisor.new, provider, definition(system_prompt: "You are a reviewer."))

    provider.systems.first.should eq("You are a reviewer.")
  end

  it "keeps the built-in prompts when there is no definition" do
    provider = CaptureProvider.new
    run(Smith::Subagents::Supervisor.new, provider, mode: Smith::Subagents::Mode::Inspect)

    provider.systems.first.should contain("inspection subagent")
  end

  it "uses the definition's tools" do
    provider = CaptureProvider.new
    run(Smith::Subagents::Supervisor.new, provider, definition(tools: ["read_file", "grep"]))

    provider.tools.first.sort.should eq(["grep", "read_file"])
  end

  it "falls back to the mode's tools when the definition names none" do
    provider = CaptureProvider.new
    run(Smith::Subagents::Supervisor.new, provider, definition(mode: Smith::Subagents::Mode::Inspect))

    provider.tools.first.should_not contain("bash")
    provider.tools.first.should contain("read_file")
  end

  it "warns about an unknown tool and keeps the rest" do
    warnings = IO::Memory.new
    provider = CaptureProvider.new
    supervisor = Smith::Subagents::Supervisor.new(warn_io: warnings)

    run(supervisor, provider, definition(tools: ["read_file", "teleport"]))

    provider.tools.first.should eq(["read_file"])
    warnings.to_s.should contain("teleport")
  end

  it "uses the definition's model, or the parent's" do
    provider = CaptureProvider.new
    supervisor = Smith::Subagents::Supervisor.new

    run(supervisor, provider, definition(model: "claude-opus-5"))
    run(supervisor, provider, definition)

    provider.models.should eq(["claude-opus-5", "parent-model"])
  end

  it "builds a second client for a definition on another provider" do
    parent = CaptureProvider.new("parent")
    other = CaptureProvider.new("other")
    supervisor = Smith::Subagents::Supervisor.new
    supervisor.provider_factory = ->(name : String) { other.as(Smith::LLM::Provider) }

    run(supervisor, parent, definition(provider: "anthropic"))

    other.systems.size.should eq(1)
    parent.systems.should be_empty
  end

  it "stays on the parent's provider when no factory was injected" do
    parent = CaptureProvider.new("parent")
    run(Smith::Subagents::Supervisor.new, parent, definition(provider: "anthropic"))

    parent.systems.size.should eq(1)
  end
end

describe "a definition that asks for the agent tool" do
  it "gets it, bounded by the nesting depth" do
    provider = CaptureProvider.new
    run(Smith::Subagents::Supervisor.new, provider, definition(tools: ["read_file", "agent"]))

    provider.tools.first.should contain("agent")
  end

  it "does not get it at the deepest level, where a further child is refused anyway" do
    provider = CaptureProvider.new
    supervisor = Smith::Subagents::Supervisor.new(depth: Smith::Subagents::Supervisor::MAX_DEPTH - 1)

    run(supervisor, provider, definition(tools: ["read_file", "agent"]))

    # Offering a tool whose every call would be refused only wastes turns.
    provider.tools.first.should_not contain("agent")
  end
end

describe "plan mode against a definition" do
  it "overrides the definition's tools, which could otherwise mutate" do
    provider = CaptureProvider.new
    supervisor = Smith::Subagents::Supervisor.new
    supervisor.plan_mode = true

    run(supervisor, provider, definition(tools: ["bash", "write_file", "read_file"]))

    provider.tools.first.should eq(["read_file"])
  end

  it "leaves a read-only definition alone" do
    provider = CaptureProvider.new
    supervisor = Smith::Subagents::Supervisor.new
    supervisor.plan_mode = true

    run(supervisor, provider, definition(tools: ["read_file", "grep"]))

    provider.tools.first.sort.should eq(["grep", "read_file"])
  end
end

private def agent_tool(catalog : Smith::Agents::Catalog, provider = CaptureProvider.new, supervisor = Smith::Subagents::Supervisor.new)
  Smith::Tools::AgentTool.new(
    supervisor: supervisor,
    provider: provider,
    model: "parent-model",
    agents: catalog
  )
end

private def catalog_with(*definitions : Smith::Agents::Definition) : Smith::Agents::Catalog
  catalog = Smith::Agents::Catalog.new
  definitions.each { |d| catalog.agents[d.name] = d }
  catalog
end

describe "the agent tool with agent_type" do
  it "runs the named definition" do
    provider = CaptureProvider.new
    tool = agent_tool(catalog_with(definition(system_prompt: "You are a reviewer.")), provider)

    tool.run(JSON.parse(%({"prompt": "review it", "agent_type": "reviewer"})))

    provider.systems.first.should eq("You are a reviewer.")
  end

  it "reports an unknown agent_type as a tool error, not a crash" do
    tool = agent_tool(catalog_with(definition))

    result = tool.run(JSON.parse(%({"prompt": "x", "agent_type": "nope"})))
    result.should start_with("Error:")
    result.should contain("nope")
    # Names what is available, so the model can correct itself.
    result.should contain("reviewer")
  end

  it "keeps the mode-based behaviour when no agent_type is given" do
    provider = CaptureProvider.new
    tool = agent_tool(catalog_with(definition), provider)

    tool.run(JSON.parse(%({"prompt": "x", "mode": "inspect"})))

    provider.systems.first.should contain("inspection subagent")
  end

  it "lists the available agents in its description" do
    tool = agent_tool(catalog_with(definition))

    tool.description.should contain("agent_type")
    tool.description.should contain("reviewer")
  end

  it "says nothing about agent_type when none are defined" do
    tool = agent_tool(Smith::Agents::Catalog.new)

    tool.description.should_not contain("agent_type")
    tool.parameters["properties"]["agent_type"]?.should be_nil
  end
end
