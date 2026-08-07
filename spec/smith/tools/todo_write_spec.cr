require "../../spec_helper"
require "../../../src/smith/tools"

private def call(id : String, args : String)
  Smith::Tools::CallRequest.new(id, "todo_write", JSON.parse(args))
end

describe Smith::Tools::TodoWrite do
  it "writes the todos into the injected list" do
    list = Smith::TodoList.new
    tool = Smith::Tools::TodoWrite.new(list)

    tool.run(JSON.parse(%({
      "todos": [
        {"content": "Add streaming to Ollama provider", "status": "in_progress"},
        {"content": "Update README", "status": "pending"}
      ]
    })))

    list.items.map(&.content).should eq(["Add streaming to Ollama provider", "Update README"])
    list.items.first.status.in_progress?.should be_true
  end

  it "confirms compactly instead of mirroring the whole list back" do
    tool = Smith::Tools::TodoWrite.new(Smith::TodoList.new)

    result = tool.run(JSON.parse(%({
      "todos": [
        {"content": "A", "status": "in_progress"},
        {"content": "B", "status": "pending"},
        {"content": "C", "status": "completed"}
      ]
    })))

    result.should eq("Todos updated: 1 in progress, 1 pending, 1 completed.")
    result.should_not contain("A")
  end

  it "accepts an empty list" do
    list = Smith::TodoList.new
    tool = Smith::Tools::TodoWrite.new(list)

    tool.run(JSON.parse(%({"todos": []})))
    list.empty?.should be_true
  end

  it "returns a clean error string when an item is missing its status" do
    tool = Smith::Tools::TodoWrite.new(Smith::TodoList.new)

    result = tool.run(JSON.parse(%({"todos": [{"content": "A"}]})))
    result.should start_with("Error:")
    result.should contain("status")
  end

  it "returns a clean error string when 'todos' is missing" do
    tool = Smith::Tools::TodoWrite.new(Smith::TodoList.new)

    tool.run(JSON.parse(%({}))).should start_with("Error:")
  end

  it "is neither parallel-safe nor mutating" do
    tool = Smith::Tools::TodoWrite.new(Smith::TodoList.new)

    tool.parallel?.should be_false
    tool.mutating?.should be_false
  end
end

describe "todo_write in the registry" do
  it "is registered by default and writes to the injected list" do
    list = Smith::TodoList.new
    registry = Smith::Tools::Registry.default(todos: list)

    registry.get("todo_write").should_not be_nil
    registry.specs.map(&.name).should contain("todo_write")

    results = registry.execute_calls([
      call("1", %({"todos": [{"content": "A", "status": "pending"}]})),
    ])

    results.first.is_error.should be_false
    list.items.map(&.content).should eq(["A"])
  end

  it "reports more than one in_progress item as a tool error" do
    list = Smith::TodoList.new
    registry = Smith::Tools::Registry.default(todos: list)

    results = registry.execute_calls([
      call("1", %({"todos": [
        {"content": "A", "status": "in_progress"},
        {"content": "B", "status": "in_progress"}
      ]})),
    ])

    results.first.is_error.should be_true
    results.first.text.not_nil!.should contain("in_progress")
    list.empty?.should be_true
  end

  it "never asks the approver, since it mutates nothing outside smith" do
    list = Smith::TodoList.new
    registry = Smith::Tools::Registry.default(Smith::Tools::DenyApprover.new, todos: list)

    results = registry.execute_calls([
      call("1", %({"todos": [{"content": "A", "status": "pending"}]})),
    ])

    results.first.is_error.should be_false
    list.items.size.should eq(1)
  end
end
