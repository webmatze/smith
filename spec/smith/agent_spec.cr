require "../spec_helper"

class MockProvider < Smith::LLM::Provider
  getter calls = Array(Smith::LLM::Request).new

  def name : String
    "mock"
  end

  def default_model : String
    "mock-model"
  end

  def complete(request : Smith::LLM::Request) : Smith::LLM::Response
    @calls << request

    if @calls.size == 1
      # Turn 1: Request tool execution (e.g. read_file)
      args = JSON.parse(%({"path": "spec/spec_helper.cr"}))
      blocks = [
        Smith::LLM::ContentBlock.text("Checking spec_helper..."),
        Smith::LLM::ContentBlock.tool_use("call_mock_1", "read_file", args),
      ]
      Smith::LLM::Response.new("resp_1", request.model, blocks, usage: Smith::LLM::Usage.new(10, 5, 15))
    else
      # Turn 2: Finish response with text
      blocks = [
        Smith::LLM::ContentBlock.text("Done checking spec_helper!"),
      ]
      Smith::LLM::Response.new("resp_2", request.model, blocks, usage: Smith::LLM::Usage.new(15, 8, 23))
    end
  end
end

describe Smith::Agent do
  it "runs multi-turn tool loops and updates state" do
    provider = MockProvider.new
    registry = Smith::Tools::Registry.default
    agent = Smith::Agent.new(provider: provider, registry: registry)

    events = Array(String).new
    agent.on_event do |event|
      case event
      when Smith::Events::AssistantText
        events << "Text: #{event.text}"
      when Smith::Events::ToolStart
        events << "ToolStart: #{event.tool_name}"
      when Smith::Events::ToolFinished
        events << "ToolFinished: #{event.tool_name}"
      when Smith::Events::TurnCompleted
        events << "TurnCompleted: #{event.turns}"
      end
    end

    agent.send("Read spec_helper file please")

    provider.calls.size.should eq(2)
    events.should contain("Text: Checking spec_helper...")
    events.should contain("ToolStart: read_file")
    events.should contain("ToolFinished: read_file")
    events.should contain("Text: Done checking spec_helper!")
    events.should contain("TurnCompleted: 2")

    agent.cumulative_usage.prompt_tokens.should eq(25)
    agent.cumulative_usage.completion_tokens.should eq(13)
    agent.cumulative_usage.total_tokens.should eq(38)
  end
end

# Returns one content-less response, then a normal one. Real models do this:
# gemma4 via Ollama puts its answer in `reasoning` and leaves `content` empty,
# so nothing survives parsing.
class EmptyResponseProvider < Smith::LLM::Provider
  getter calls = 0

  def name : String
    "mock"
  end

  def default_model : String
    "mock-model"
  end

  def complete(request : Smith::LLM::Request) : Smith::LLM::Response
    @calls += 1
    Smith::LLM::Response.new("resp_#{@calls}", request.model, Array(Smith::LLM::ContentBlock).new)
  end
end

describe "a response with no content blocks" do
  it "is not recorded in the transcript" do
    provider = EmptyResponseProvider.new
    agent = Smith::Agent.new(provider: provider, registry: Smith::Tools::Registry.new)

    agent.send("hello")

    # An empty assistant message carries nothing, and serializes to
    # `content: null` with no tool_calls — which providers reject, breaking
    # every later turn in the session.
    agent.messages.map(&.role).should eq([Smith::LLM::Role::User])
  end

  it "still ends the turn rather than looping" do
    provider = EmptyResponseProvider.new
    agent = Smith::Agent.new(provider: provider, registry: Smith::Tools::Registry.new)

    completed = 0
    agent.on_event { |e| completed += 1 if e.is_a?(Smith::Events::TurnCompleted) }

    agent.send("hello")

    provider.calls.should eq(1)
    completed.should eq(1)
  end
end

class TextOnlyProvider < Smith::LLM::Provider
  getter calls = 0

  def name : String
    "mock"
  end

  def default_model : String
    "mock-model"
  end

  def complete(request : Smith::LLM::Request) : Smith::LLM::Response
    @calls += 1
    Smith::LLM::Response.new("resp_#{@calls}", request.model, [
      Smith::LLM::ContentBlock.text("All done."),
    ])
  end
end

private def stop_hook(command : String)
  Smith::Hooks::Runner.new(
    [Smith::Hooks::Definition.new(event: Smith::Hooks::Event::Stop, command: command)],
    warn_io: IO::Memory.new
  )
end

private def agent_with(provider, hooks)
  Smith::Agent.new(
    provider: provider,
    registry: Smith::Tools::Registry.new,
    model: "mock-model",
    hooks: hooks
  )
end

describe "the stop hook" do
  it "lets the turn end when it does not block" do
    provider = TextOnlyProvider.new
    agent_with(provider, stop_hook("echo 'tests pass'")).send("hi")

    provider.calls.should eq(1)
  end

  it "continues the loop when it blocks, handing the reason to the model" do
    provider = TextOnlyProvider.new
    agent = agent_with(provider, stop_hook(%(
      if [ -f #{Process::INITIAL_PWD}/.smith-stop-marker ]; then exit 0; fi
      touch #{Process::INITIAL_PWD}/.smith-stop-marker
      echo 'the tests are red' >&2
      exit 2
    )))

    begin
      agent.send("hi")

      # One extra round-trip, and the model was told why.
      provider.calls.should eq(2)
      last_user = agent.messages.select(&.role.user?).last
      last_user.content.first.text.not_nil!.should contain("the tests are red")
    ensure
      File.delete("#{Process::INITIAL_PWD}/.smith-stop-marker") if File.exists?("#{Process::INITIAL_PWD}/.smith-stop-marker")
    end
  end

  it "gives up after a bounded number of continuations" do
    provider = TextOnlyProvider.new

    # A hook that never goes green would otherwise loop until MAX_TURNS.
    agent_with(provider, stop_hook("echo 'still red' >&2; exit 2")).send("hi")

    provider.calls.should eq(Smith::Agent::MAX_STOP_CONTINUATIONS + 1)
  end
end

describe "a turn that produced nothing" do
  it "says so, instead of looking like nothing happened" do
    provider = EmptyResponseProvider.new
    agent = Smith::Agent.new(provider: provider, registry: Smith::Tools::Registry.new)

    seen = [] of Smith::Events::Event
    agent.on_event { |event| seen << event }

    agent.send("hello")

    seen.any?(Smith::Events::EmptyResponse).should be_true
    # Still a completed turn, not a provider failure.
    seen.any?(Smith::Events::TurnCompleted).should be_true
    seen.any?(Smith::Events::TurnError).should be_false
  end

  it "stays quiet when the model did answer" do
    provider = TextOnlyProvider.new
    agent = Smith::Agent.new(provider: provider, registry: Smith::Tools::Registry.new)

    seen = [] of Smith::Events::Event
    agent.on_event { |event| seen << event }

    agent.send("hello")

    seen.any?(Smith::Events::EmptyResponse).should be_false
  end
end
