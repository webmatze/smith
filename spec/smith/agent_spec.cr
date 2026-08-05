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
        Smith::LLM::ContentBlock.tool_use("call_mock_1", "read_file", args)
      ]
      Smith::LLM::Response.new("resp_1", request.model, blocks, usage: Smith::LLM::Usage.new(10, 5, 15))
    else
      # Turn 2: Finish response with text
      blocks = [
        Smith::LLM::ContentBlock.text("Done checking spec_helper!")
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
