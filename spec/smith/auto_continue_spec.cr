require "../spec_helper"

# Answers with whatever the script says, so each truncation case can be driven
# exactly.
private class ScriptedProvider < Smith::LLM::Provider
  getter calls = 0
  getter requests = Array(Smith::LLM::Request).new

  def initialize(@script : Array(Smith::LLM::Response))
  end

  def name : String
    "mock"
  end

  def default_model : String
    "mock-model"
  end

  def complete(request : Smith::LLM::Request) : Smith::LLM::Response
    @requests << request
    @calls += 1
    @script[Math.min(@calls - 1, @script.size - 1)]
  end
end

private def response(blocks : Array(Smith::LLM::ContentBlock), stop : String)
  Smith::LLM::Response.new("r", "mock-model", blocks, stop_reason: stop)
end

private def text(content : String)
  Smith::LLM::ContentBlock.text(content)
end

private def tool_use(name : String = "write_file")
  Smith::LLM::ContentBlock.tool_use("call_1", name, JSON.parse(%({"path": "a.txt", "content": "x"})))
end

private def run(script : Array(Smith::LLM::Response))
  provider = ScriptedProvider.new(script)
  agent = Smith::Agent.new(provider: provider, registry: Smith::Tools::Registry.new, model: "mock-model")

  events = [] of Smith::Events::Event
  agent.on_event { |event| events << event }
  agent.send("go")

  {provider, agent, events}
end

# What the model is told to do next, i.e. the last user turn.
private def last_instruction(agent) : String
  agent.messages.select(&.role.user?).last.content.compact_map(&.text).join
end

describe "a text response cut off at the output limit" do
  it "is continued automatically" do
    provider, agent, events = run([
      response([text("The first half")], "max_tokens"),
      response([text(" and the second.")], "end_turn"),
    ])

    provider.calls.should eq(2)
    events.count(&.is_a?(Smith::Events::ResponseContinued)).should eq(1)
    agent.messages.select(&.role.assistant?).map(&.content.compact_map(&.text).join)
      .should eq(["The first half", " and the second."])
  end

  it "keeps what was already written and says not to repeat it" do
    _provider, agent, _events = run([
      response([text("half")], "max_tokens"),
      response([text("rest")], "end_turn"),
    ])

    instruction = last_instruction(agent)
    instruction.should contain("cut off")
    instruction.should contain("Do not repeat")
  end

  it "leaves a normal response completely alone" do
    provider, agent, events = run([response([text("all done")], "end_turn")])

    provider.calls.should eq(1)
    events.any?(Smith::Events::ResponseContinued).should be_false
    agent.messages.size.should eq(2)
  end
end

describe "a tool call cut off at the output limit" do
  it "is thrown away rather than half-executed" do
    provider, agent, _events = run([
      response([text("writing the file"), tool_use], "max_tokens"),
      response([text("ok")], "end_turn"),
    ])

    provider.calls.should eq(2)

    # A half tool_use cannot be completed, and providers reject one without a
    # matching tool_result — so it must not reach the transcript at all.
    blocks = agent.messages.flat_map(&.content)
    blocks.any?(&.type.tool_use?).should be_false
    blocks.any?(&.type.tool_result?).should be_false
    # The text it managed to produce is worth keeping.
    blocks.compact_map(&.text).join.should contain("writing the file")
  end

  it "tells the model to retry with a smaller payload" do
    _provider, agent, _events = run([
      response([tool_use], "max_tokens"),
      response([text("ok")], "end_turn"),
    ])

    instruction = last_instruction(agent)
    instruction.should contain("tool call was cut off")
    instruction.should contain("smaller")
  end

  it "does not execute the tool" do
    path = File.join(Dir.tempdir, "smith_autocont_#{Random::Secure.hex(4)}.txt")
    provider = ScriptedProvider.new([
      response([Smith::LLM::ContentBlock.tool_use("c1", "write_file", JSON.parse({"path" => path, "content" => "x"}.to_json))], "max_tokens"),
      response([text("ok")], "end_turn"),
    ])

    agent = Smith::Agent.new(provider: provider, registry: Smith::Tools::Registry.default, model: "mock-model")
    agent.send("go")

    File.exists?(path).should be_false
  end
end

describe "the continuation limit" do
  it "gives up after three, rather than burning budget indefinitely" do
    provider, _agent, events = run([response([text("more")], "max_tokens")])

    # The first call plus three continuations.
    provider.calls.should eq(Smith::Agent::MAX_CONTINUATIONS + 1)
    events.count(&.is_a?(Smith::Events::ResponseContinued)).should eq(Smith::Agent::MAX_CONTINUATIONS)
    events.any?(Smith::Events::TurnError).should be_true
  end

  it "counts per send, so a long session does not run out" do
    # One truncation and one completion per send.
    provider = ScriptedProvider.new([
      response([text("half")], "max_tokens"),
      response([text("rest")], "end_turn"),
      response([text("half again")], "max_tokens"),
      response([text("rest again")], "end_turn"),
    ])
    agent = Smith::Agent.new(provider: provider, registry: Smith::Tools::Registry.new, model: "mock-model")

    agent.send("first")
    agent.send("second")

    # Two continuations used across two sends, neither exhausting the budget.
    provider.calls.should eq(4)
  end
end
