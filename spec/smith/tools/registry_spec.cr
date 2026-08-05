require "../../spec_helper"
require "../../../src/smith/tools"

describe Smith::Tools::Registry do
  it "registers default tools" do
    registry = Smith::Tools::Registry.default
    registry.get("bash").should_not be_nil
    registry.get("read_file").should_not be_nil
    registry.get("write_file").should_not be_nil
    registry.get("edit_file").should_not be_nil
    registry.get("grep").should_not be_nil
    registry.get("glob").should_not be_nil
  end

  it "executes parallel tools concurrently" do
    registry = Smith::Tools::Registry.default

    # Create temporary file to read
    test_path = "tmp_test_read.txt"
    File.write(test_path, "Line 1: Hello\nLine 2: World")

    begin
      calls = [
        Smith::Tools::CallRequest.new("1", "read_file", JSON.parse(%({"path": "#{test_path}"}))),
        Smith::Tools::CallRequest.new("2", "glob", JSON.parse(%({"pattern": "tmp_*.txt"})))
      ]

      results = registry.execute_calls(calls)
      results.size.should eq(2)
      results[0].tool_call_id.should eq("1")
      results[0].text.not_nil!.should contain("Line 1: Hello")
      results[1].tool_call_id.should eq("2")
      results[1].text.not_nil!.should contain(test_path)
    ensure
      File.delete(test_path) if File.exists?(test_path)
    end
  end

  it "executes bash tool" do
    registry = Smith::Tools::Registry.default
    calls = [
      Smith::Tools::CallRequest.new("c1", "bash", JSON.parse(%({"command": "echo 'Hello Smith'"})))
    ]

    results = registry.execute_calls(calls)
    results.size.should eq(1)
    results[0].text.not_nil!.strip.should eq("Hello Smith")
  end
end
