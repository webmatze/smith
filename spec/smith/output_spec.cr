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

private def todos_updated(*items : Tuple(String, Smith::TodoList::Status))
  Smith::Events::TodosUpdated.new(
    items.to_a.map { |(content, status)| Smith::TodoList::Item.new(content, status) }
  )
end

describe "todo rendering" do
  it "renders the list with a marker per status (human)" do
    stdout_io = IO::Memory.new
    renderer = Smith::Output::HumanRenderer.new(stdout_io)

    renderer.handle(todos_updated(
      {"Write the spec", Smith::TodoList::Status::Completed},
      {"Implement the tool", Smith::TodoList::Status::InProgress},
      {"Update the README", Smith::TodoList::Status::Pending},
    ))

    text = stdout_io.to_s
    text.should contain("☑")
    text.should contain("▶")
    text.should contain("☐")
    text.should contain("Write the spec")
    text.should contain("Implement the tool")
    text.should contain("Update the README")
  end

  it "says so when the list was cleared (human)" do
    stdout_io = IO::Memory.new
    renderer = Smith::Output::HumanRenderer.new(stdout_io)

    renderer.handle(Smith::Events::TodosUpdated.new([] of Smith::TodoList::Item))

    stdout_io.to_s.should contain("Todos cleared")
  end

  it "emits one todos_updated object with all items (json)" do
    stdout_io = IO::Memory.new
    renderer = Smith::Output::JsonRenderer.new(stdout_io, IO::Memory.new)

    renderer.handle(todos_updated(
      {"Implement the tool", Smith::TodoList::Status::InProgress},
      {"Update the README", Smith::TodoList::Status::Pending},
    ))

    lines = parsed_lines(stdout_io)
    lines.size.should eq(1)
    lines.first["type"].as_s.should eq("todos_updated")

    todos = lines.first["todos"].as_a
    todos.size.should eq(2)
    todos[0]["content"].as_s.should eq("Implement the tool")
    todos[0]["status"].as_s.should eq("in_progress")
    todos[1]["status"].as_s.should eq("pending")
  end
end

describe "plan mode rendering" do
  it "renders the plan and the mode switch (human)" do
    stdout_io = IO::Memory.new
    renderer = Smith::Output::HumanRenderer.new(stdout_io)

    renderer.handle(Smith::Events::ModeChanged.new(Smith::Mode::Plan))
    renderer.handle(Smith::Events::PlanPresented.new("1. Read the file\n2. Patch it"))
    renderer.handle(Smith::Events::ModeChanged.new(Smith::Mode::Normal))

    text = stdout_io.to_s
    text.should contain("📋 Plan")
    text.should contain("1. Read the file")
    text.should contain("2. Patch it")
    text.should contain("plan mode")
    text.should contain("normal mode")
  end

  it "emits plan_presented and mode_changed (json)" do
    stdout_io = IO::Memory.new
    renderer = Smith::Output::JsonRenderer.new(stdout_io, IO::Memory.new)

    renderer.handle(Smith::Events::ModeChanged.new(Smith::Mode::Plan))
    renderer.handle(Smith::Events::PlanPresented.new("1. Read\n2. Patch"))

    lines = parsed_lines(stdout_io)
    lines.map(&.["type"].as_s).should eq(%w[mode_changed plan_presented])
    lines[0]["mode"].as_s.should eq("plan")
    lines[1]["plan"].as_s.should eq("1. Read\n2. Patch")
  end
end

describe "hook rendering" do
  it "names the event and the command, and marks a block (human)" do
    stdout_io = IO::Memory.new
    renderer = Smith::Output::HumanRenderer.new(stdout_io)

    renderer.handle(Smith::Events::HookFired.new(Smith::Hooks::Event::PostToolUse, "format.sh", false))
    renderer.handle(Smith::Events::HookFired.new(Smith::Hooks::Event::PreToolUse, "deny.sh", true))

    text = stdout_io.to_s
    text.should contain("post_tool_use")
    text.should contain("format.sh")
    text.should contain("pre_tool_use")
    text.should contain("blocked")
  end

  it "emits hook_fired (json)" do
    stdout_io = IO::Memory.new
    renderer = Smith::Output::JsonRenderer.new(stdout_io, IO::Memory.new)

    renderer.handle(Smith::Events::HookFired.new(Smith::Hooks::Event::Stop, "make test", true))

    line = parsed_lines(stdout_io).first
    line["type"].as_s.should eq("hook_fired")
    line["event"].as_s.should eq("stop")
    line["command"].as_s.should eq("make test")
    line["blocked"].as_bool.should be_true
  end
end

private def cached_usage
  Smith::LLM::Usage.new(7126, 132, 7258, cache_creation_tokens: 1226, cache_read_tokens: 5900)
end

describe "cache usage reporting" do
  it "shows the cached share next to the prompt tokens (human)" do
    stdout_io = IO::Memory.new
    Smith::Output::HumanRenderer.new(stdout_io).finish(cached_usage)

    stdout_io.to_s.should contain("7126 prompt (7126 cached)")
  end

  it "stays quiet about caching when nothing was cached (human)" do
    stdout_io = IO::Memory.new
    Smith::Output::HumanRenderer.new(stdout_io).finish(usage)

    stdout_io.to_s.should_not contain("cached")
  end

  it "always reports both counters (json)" do
    stdout_io = IO::Memory.new
    Smith::Output::JsonRenderer.new(stdout_io, IO::Memory.new).finish(cached_usage)

    reported = parsed_lines(stdout_io).first["usage"]
    reported["cache_creation_tokens"].as_i.should eq(1226)
    reported["cache_read_tokens"].as_i.should eq(5900)
  end
end

describe "an empty response" do
  it "is visible to a human, and not counted as a failure" do
    stdout_io = IO::Memory.new
    renderer = Smith::Output::HumanRenderer.new(stdout_io)

    renderer.handle(Smith::Events::EmptyResponse.new)

    stdout_io.to_s.should contain("empty response")
    renderer.exit_code.should eq(0)
  end

  it "is reported as its own event under --json" do
    stdout_io = IO::Memory.new
    renderer = Smith::Output::JsonRenderer.new(stdout_io, IO::Memory.new)

    renderer.handle(Smith::Events::EmptyResponse.new)

    parsed_lines(stdout_io).first["type"].as_s.should eq("empty_response")
  end
end

describe "background job reporting" do
  it "names the job and its command, then its status (human)" do
    stdout_io = IO::Memory.new
    renderer = Smith::Output::HumanRenderer.new(stdout_io)

    renderer.handle(Smith::Events::BashJobStarted.new("bash-1", "npm run dev"))
    renderer.handle(Smith::Events::BashJobExited.new("bash-1", "exited(1)"))

    text = stdout_io.to_s
    text.should contain("bash-1")
    text.should contain("npm run dev")
    text.should contain("exited(1)")
  end

  it "emits both as their own events (json)" do
    stdout_io = IO::Memory.new
    renderer = Smith::Output::JsonRenderer.new(stdout_io, IO::Memory.new)

    renderer.handle(Smith::Events::BashJobStarted.new("bash-1", "npm run dev"))
    renderer.handle(Smith::Events::BashJobExited.new("bash-1", "killed"))

    lines = parsed_lines(stdout_io)
    lines.map(&.["type"].as_s).should eq(["bash_job_started", "bash_job_exited"])
    lines[0]["command"].as_s.should eq("npm run dev")
    lines[1]["status"].as_s.should eq("killed")
  end
end

describe "a continued response" do
  it "explains the extra provider calls (human)" do
    stdout_io = IO::Memory.new
    Smith::Output::HumanRenderer.new(stdout_io).handle(Smith::Events::ResponseContinued.new(1, 3))

    stdout_io.to_s.should contain("output limit")
    stdout_io.to_s.should contain("(1/3)")
  end

  it "is its own event (json)" do
    stdout_io = IO::Memory.new
    Smith::Output::JsonRenderer.new(stdout_io, IO::Memory.new).handle(Smith::Events::ResponseContinued.new(2, 3))

    line = parsed_lines(stdout_io).first
    line["type"].as_s.should eq("response_continued")
    line["attempt"].as_i.should eq(2)
  end
end

describe "thinking output" do
  it "sets reasoning apart from the answer (human)" do
    stdout_io = IO::Memory.new
    renderer = Smith::Output::HumanRenderer.new(stdout_io)

    renderer.handle(Smith::Events::ThinkingDelta.new("weighing options"))
    renderer.handle(Smith::Events::AssistantTextDelta.new("the answer"))

    text = stdout_io.to_s
    text.should contain("weighing options")
    text.should contain("the answer")
    # Dimmed and italic, so it cannot be mistaken for the answer.
    text.should contain("\e[2;3m")
  end

  it "notes redacted thinking without showing it" do
    stdout_io = IO::Memory.new
    Smith::Output::HumanRenderer.new(stdout_io)
      .handle(Smith::Events::ThinkingBlock.new("encrypted-payload", redacted: true))

    stdout_io.to_s.should contain("redacted")
    stdout_io.to_s.should_not contain("encrypted-payload")
  end

  it "uses its own event types, leaving assistant_text consumers alone (json)" do
    stdout_io = IO::Memory.new
    renderer = Smith::Output::JsonRenderer.new(stdout_io, IO::Memory.new)

    renderer.handle(Smith::Events::ThinkingDelta.new("weighing"))
    renderer.handle(Smith::Events::ThinkingBlock.new("secret", redacted: true))

    lines = parsed_lines(stdout_io)
    lines.map(&.["type"].as_s).should eq(["thinking_delta", "thinking_block"])
    lines[0]["text"].as_s.should eq("weighing")
    lines[1]["redacted"].as_bool.should be_true
    lines[1]["text"].as_s.should be_empty
  end
end
