require "../spec_helper"
require "../../src/smith/output"

private def usage(prompt = 10, completion = 5)
  Smith::LLM::Usage.new(prompt, completion, prompt + completion)
end

private def tool_start(id = "call_1", name = "bash")
  Smith::Events::ToolStart.new(id, name, JSON.parse(%({"command": "ls"})))
end

# Every line must parse on its own — that is the property a consumer relies on.
private def parsed_lines(io : IO::Memory) : Array(JSON::Any)
  io.to_s.lines.reject(&.strip.empty?).map { |line| JSON.parse(line) }
end

describe Smith::Output::JsonRenderer do
  it "emits one self-contained JSON object per line" do
    stdout_io = IO::Memory.new
    renderer = Smith::Output::JsonRenderer.new(stdout_io, IO::Memory.new)

    renderer.handle(Smith::Events::AssistantText.new("hello"))
    renderer.handle(tool_start)
    renderer.handle(Smith::Events::ToolFinished.new("call_1", "bash", "README.md", false))
    renderer.finish(usage)

    lines = parsed_lines(stdout_io)
    lines.size.should eq(4)
    lines.map(&.["type"].as_s).should eq(%w[assistant_text tool_start tool_finished result])
  end

  it "emits the documented fields for each event type" do
    stdout_io = IO::Memory.new
    renderer = Smith::Output::JsonRenderer.new(stdout_io, IO::Memory.new)

    renderer.handle(tool_start)
    renderer.handle(Smith::Events::ToolFinished.new("call_1", "bash", "boom", true))
    renderer.handle(Smith::Events::HistoryCompacted.new(2779, 548, "truncated"))
    renderer.handle(Smith::Events::TurnError.new("provider exploded"))

    start, finished, compacted, error = parsed_lines(stdout_io)

    start["id"].as_s.should eq("call_1")
    start["tool"].as_s.should eq("bash")
    start["args"]["command"].as_s.should eq("ls")

    finished["is_error"].as_bool.should be_true
    finished["result"].as_s.should eq("boom")

    compacted["strategy"].as_s.should eq("truncated")
    compacted["before_tokens"].as_i.should eq(2779)
    compacted["after_tokens"].as_i.should eq(548)

    error["error"].as_s.should eq("provider exploded")
  end

  it "puts the reassembled answer in a final result line" do
    stdout_io = IO::Memory.new
    renderer = Smith::Output::JsonRenderer.new(stdout_io, IO::Memory.new)

    # Assistant text arrives one block at a time.
    renderer.handle(Smith::Events::AssistantText.new("There are "))
    renderer.handle(Smith::Events::AssistantText.new("12 files."))
    renderer.finish(usage(prompt: 7126, completion: 132))

    last = parsed_lines(stdout_io).last
    last["type"].as_s.should eq("result")
    last["text"].as_s.should eq("There are 12 files.")
    last["usage"]["prompt_tokens"].as_i.should eq(7126)
    last["usage"]["total_tokens"].as_i.should eq(7258)
  end

  it "keeps stdout free of anything that is not JSON" do
    stdout_io = IO::Memory.new
    stderr_io = IO::Memory.new
    renderer = Smith::Output::JsonRenderer.new(stdout_io, stderr_io)

    renderer.banner("ollama", "gemma4:12b-mlx", ["test-skill"])
    renderer.handle(Smith::Events::AssistantText.new("hi"))
    renderer.finish(usage)

    # Decoration lands on stderr...
    stderr_io.to_s.should contain("Running Smith Headless")
    stderr_io.to_s.should contain("test-skill")

    # ...and never on stdout.
    stdout_io.to_s.should_not contain("Running Smith Headless")
    parsed_lines(stdout_io).size.should eq(2)
  end

  it "sends approval prompts to stderr so they cannot corrupt the stream" do
    stdout_io = IO::Memory.new
    stderr_io = IO::Memory.new
    renderer = Smith::Output::JsonRenderer.new(stdout_io, stderr_io)

    renderer.prompt_io.should be(stderr_io)
  end

  describe "exit codes" do
    it "reports success for a clean run" do
      renderer = Smith::Output::JsonRenderer.new(IO::Memory.new, IO::Memory.new)
      renderer.handle(Smith::Events::AssistantText.new("done"))

      renderer.exit_code.should eq(0)
    end

    it "reports failure after a turn error" do
      renderer = Smith::Output::JsonRenderer.new(IO::Memory.new, IO::Memory.new)
      renderer.handle(Smith::Events::TurnError.new("provider exploded"))

      renderer.exit_code.should eq(1)
    end

    it "does not treat a tool error as a failed run" do
      renderer = Smith::Output::JsonRenderer.new(IO::Memory.new, IO::Memory.new)
      renderer.handle(Smith::Events::ToolFinished.new("c1", "grep", "no matches", true))

      renderer.exit_code.should eq(0)
    end
  end
end

describe Smith::Output::HumanRenderer do
  it "still renders the familiar decorated output" do
    stdout_io = IO::Memory.new
    renderer = Smith::Output::HumanRenderer.new(stdout_io)

    renderer.banner("ollama", "gemma4:12b-mlx", ["test-skill"])
    renderer.handle(Smith::Events::AssistantTextDelta.new("hello"))
    renderer.handle(Smith::Events::AssistantText.new("hello"))
    renderer.handle(tool_start)
    renderer.handle(Smith::Events::ToolFinished.new("call_1", "bash", "ok", false))
    renderer.handle(Smith::Events::HistoryCompacted.new(2779, 548, "truncated"))
    renderer.finish(usage)

    text = stdout_io.to_s
    text.should contain("Running Smith Headless")
    text.should contain("Loaded Skills: test-skill")
    text.should contain("hello")
    text.should contain("Executing tool")
    text.should contain("finished")
    text.should contain("Context compacted")
    text.should contain("📊 Usage:")
  end

  it "prints deltas once, not twice" do
    stdout_io = IO::Memory.new
    renderer = Smith::Output::HumanRenderer.new(stdout_io)

    # The agent emits both: deltas for live display, then the finished block.
    # Printing both would show the answer twice.
    renderer.handle(Smith::Events::AssistantTextDelta.new("There are "))
    renderer.handle(Smith::Events::AssistantTextDelta.new("12 files."))
    renderer.handle(Smith::Events::AssistantText.new("There are 12 files."))

    stdout_io.to_s.should eq("There are 12 files.")
    # The answer still comes from AssistantText, which is what `result` uses.
    renderer.answer.should eq("There are 12 files.")
  end

  it "shares the exit-code rule with the JSON renderer" do
    renderer = Smith::Output::HumanRenderer.new(IO::Memory.new)
    renderer.exit_code.should eq(0)

    renderer.handle(Smith::Events::TurnError.new("boom"))
    renderer.exit_code.should eq(1)
  end
end
