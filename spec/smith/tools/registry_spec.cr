require "file_utils"
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
        Smith::Tools::CallRequest.new("2", "glob", JSON.parse(%({"pattern": "tmp_*.txt"}))),
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
      Smith::Tools::CallRequest.new("c1", "bash", JSON.parse(%({"command": "echo 'Hello Smith'"}))),
    ]

    results = registry.execute_calls(calls)
    results.size.should eq(1)
    results[0].text.not_nil!.strip.should eq("Hello Smith")
  end
end

describe "a tool result that carries an attachment" do
  it "hangs the image off the same call id, beside the result" do
    dir = File.join(Dir.tempdir, "smith-registry-media-#{Random.rand(100_000)}")
    Dir.mkdir_p(dir)
    path = File.join(dir, "shot.png")
    File.open(path, "w") { |file| file.write(Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01]) }

    begin
      registry = Smith::Tools::Registry.default
      results = registry.execute_calls([
        Smith::Tools::CallRequest.new("c1", "read_file", JSON.parse(%({"path": "#{path}"}))),
        Smith::Tools::CallRequest.new("c2", "glob", JSON.parse(%({"pattern": "*.nothing"}))),
      ])

      # Three blocks for two calls: result, its image, and the second result.
      results.size.should eq(3)
      results[0].type.tool_result?.should be_true
      results[0].tool_call_id.should eq("c1")
      results[1].type.image?.should be_true
      results[1].tool_call_id.should eq("c1")
      results[1].data.should_not be_nil
      results[2].tool_call_id.should eq("c2")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "carries nothing when the call never ran" do
    registry = Smith::Tools::Registry.default
    results = registry.execute_calls([
      Smith::Tools::CallRequest.new("c1", "no_such_tool", JSON.parse("{}")),
    ])

    results.size.should eq(1)
    results.first.is_error.should be_true
  end
end
