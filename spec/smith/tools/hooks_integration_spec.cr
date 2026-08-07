require "../../spec_helper"
require "../../../src/smith/tools"
require "../../../src/smith/hooks"

private def hook(command : String, event : Smith::Hooks::Event, matcher : String? = nil)
  Smith::Hooks::Definition.new(
    event: event,
    command: command,
    matcher: matcher.try { |m| Regex.new(m) }
  )
end

private def registry_with(*definitions : Smith::Hooks::Definition, approver = Smith::Tools::AutoApprover.new)
  registry = Smith::Tools::Registry.default(approver)
  registry.hooks = Smith::Hooks::Runner.new(definitions.to_a, warn_io: IO::Memory.new)
  registry
end

private def write_call(path : String, content : String = "hello", id : String = "1")
  Smith::Tools::CallRequest.new(id, "write_file", JSON.parse({"path" => path, "content" => content}.to_json))
end

private def with_temp_path(&)
  path = File.tempname("smith_hookint", ".txt")
  begin
    yield path
  ensure
    File.delete(path) if File.exists?(path)
  end
end

describe "pre_tool_use in the registry" do
  it "blocks the call and hands the reason to the model" do
    with_temp_path do |path|
      registry = registry_with(hook("echo 'not allowed' >&2; exit 2", Smith::Hooks::Event::PreToolUse))

      result = registry.execute_calls([write_call(path)]).first

      result.is_error.should be_true
      result.text.not_nil!.should contain("not allowed")
      File.exists?(path).should be_false, "the tool ran despite the block"
    end
  end

  it "runs before the approval gate, so a blocked call is never even asked about" do
    with_temp_path do |path|
      registry = registry_with(
        hook(%(echo '{"decision":"deny","reason":"policy"}'), Smith::Hooks::Event::PreToolUse),
        approver: Smith::Tools::DenyApprover.new
      )

      result = registry.execute_calls([write_call(path)]).first

      # The hook's reason wins over the approver's — proving the order.
      result.text.not_nil!.should contain("policy")
    end
  end

  it "replaces the tool arguments via updated_input" do
    with_temp_path do |path|
      redirected = "#{path}.redirected"
      begin
        registry = registry_with(hook(
          %(echo '{"updated_input":{"path":"#{redirected}","content":"rewritten"}}'),
          Smith::Hooks::Event::PreToolUse
        ))

        registry.execute_calls([write_call(path)]).first.is_error.should be_false

        File.exists?(path).should be_false
        File.read(redirected).should eq("rewritten")
      ensure
        File.delete(redirected) if File.exists?(redirected)
      end
    end
  end

  it "only fires for tools its matcher covers" do
    with_temp_path do |path|
      registry = registry_with(hook("exit 2", Smith::Hooks::Event::PreToolUse, matcher: "bash"))

      registry.execute_calls([write_call(path)]).first.is_error.should be_false
      File.exists?(path).should be_true
    end
  end

  it "forces an approval prompt for a tool that would otherwise bypass the gate" do
    registry = registry_with(
      hook(%(echo '{"decision":"ask"}'), Smith::Hooks::Event::PreToolUse),
      approver: Smith::Tools::DenyApprover.new
    )

    # read_file is not mutating and normally never reaches the approver.
    result = registry.execute_calls([
      Smith::Tools::CallRequest.new("1", "read_file", JSON.parse(%({"path": "README.md"}))),
    ]).first

    result.is_error.should be_true
    result.text.not_nil!.should contain("requires approval")
  end
end

describe "post_tool_use in the registry" do
  it "appends the hook output to the tool result" do
    with_temp_path do |path|
      registry = registry_with(hook("echo 'formatted 1 file'", Smith::Hooks::Event::PostToolUse))

      result = registry.execute_calls([write_call(path)]).first

      result.is_error.should be_false
      result.text.not_nil!.should contain("formatted 1 file")
    end
  end

  it "sees the tool result in its payload" do
    with_temp_path do |path|
      marker = File.tempname("smith_hookint", ".json")
      begin
        registry = registry_with(hook("cat > #{marker}", Smith::Hooks::Event::PostToolUse))

        registry.execute_calls([write_call(path)])

        received = JSON.parse(File.read(marker))
        received["tool_name"].as_s.should eq("write_file")
        received["tool_args"]["path"].as_s.should eq(path)
        received["tool_result"].as_s.should_not be_empty
      ensure
        File.delete(marker) if File.exists?(marker)
      end
    end
  end

  it "does not run after a call that never executed" do
    with_temp_path do |path|
      marker = File.tempname("smith_hookint", ".txt")
      begin
        registry = registry_with(
          hook("exit 2", Smith::Hooks::Event::PreToolUse),
          hook("echo fired > #{marker}", Smith::Hooks::Event::PostToolUse)
        )

        registry.execute_calls([write_call(path)])

        File.exists?(marker).should be_false
      ensure
        File.delete(marker) if File.exists?(marker)
      end
    end
  end
end
