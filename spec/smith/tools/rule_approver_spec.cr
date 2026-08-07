require "../../spec_helper"
require "../../../src/smith/tools"

private def rule_approver(
  inner : Smith::Tools::Approver = Smith::Tools::AutoApprover.new,
  allow = [] of String,
  ask = [] of String,
  deny = [] of String,
  project_dir = "/project",
)
  Smith::Tools::RuleApprover.new(
    Smith::Tools::RuleSet.build(allow: allow, ask: ask, deny: deny, project_dir: project_dir),
    inner
  )
end

private def bash_call(command : String)
  Smith::Tools::CallRequest.new("1", "bash", JSON.parse({"command" => command}.to_json))
end

# Records whether it was consulted, so delegation can be observed.
private class SpyApprover < Smith::Tools::Approver
  getter asked = 0

  def initialize(@answer : Bool = true)
  end

  def approve?(tool : Smith::Tools::Tool, call : Smith::Tools::CallRequest) : Bool
    @asked += 1
    @answer
  end
end

describe Smith::Tools::RuleApprover do
  it "allows without consulting anyone" do
    spy = SpyApprover.new(false)
    approver = rule_approver(inner: spy, allow: ["bash(ls)"])

    approver.approve?(Smith::Tools::Bash.new, bash_call("ls")).should be_true
    spy.asked.should eq(0)
  end

  it "denies without consulting anyone" do
    spy = SpyApprover.new(true)
    approver = rule_approver(inner: spy, deny: ["bash(rm -rf *)"])

    approver.approve?(Smith::Tools::Bash.new, bash_call("rm -rf /")).should be_false
    spy.asked.should eq(0)
  end

  it "delegates anything the rules do not settle" do
    spy = SpyApprover.new(true)
    approver = rule_approver(inner: spy)

    approver.approve?(Smith::Tools::Bash.new, bash_call("npm test")).should be_true
    spy.asked.should eq(1)
  end

  it "asks even for something an allow rule would have covered" do
    spy = SpyApprover.new(false)
    approver = rule_approver(inner: spy, allow: ["bash(git *)"], ask: ["bash(git push *)"])

    approver.approve?(Smith::Tools::Bash.new, bash_call("git push origin main")).should be_false
    spy.asked.should eq(1)
  end

  it "denies even under --yes" do
    # AutoApprover is what --yes installs. A deny rule has to survive it, or
    # the flag quietly disables the secret protection it was never about.
    approver = rule_approver(inner: Smith::Tools::AutoApprover.new, deny: ["bash(rm -rf *)"])

    approver.approve?(Smith::Tools::Bash.new, bash_call("rm -rf /")).should be_false
  end

  it "denies even after the user answered [a]lways for that tool" do
    prompt = Smith::Tools::PromptApprover.new(input: IO::Memory.new("a\ny\n"), output: IO::Memory.new)
    approver = rule_approver(inner: prompt, deny: ["bash(rm -rf *)"])

    # First a harmless call, answered with [a]lways.
    approver.approve?(Smith::Tools::Bash.new, bash_call("ls")).should be_true
    # The session-wide yes must not reach past the deny rule.
    approver.approve?(Smith::Tools::Bash.new, bash_call("rm -rf /")).should be_false
  end

  it "names the rule when it refuses" do
    approver = rule_approver(deny: ["bash(rm -rf *)"])
    message = approver.denial_message(Smith::Tools::Bash.new, bash_call("rm -rf /"))

    message.should contain("bash(rm -rf *)")
    message.should contain("deny")
  end

  it "passes the inner approver's message through when it was the one refusing" do
    approver = rule_approver(inner: Smith::Tools::DenyApprover.new)
    message = approver.denial_message(Smith::Tools::Bash.new, bash_call("npm test"))

    message.should contain("--yes")
  end

  it "reports which tools it governs, so the registry knows what to gate" do
    approver = rule_approver(deny: ["read_file(**/.ssh/**)"])

    approver.governs?(Smith::Tools::ReadFile.new).should be_true
    approver.governs?(Smith::Tools::Glob.new).should be_false
  end
end

describe "deny rules in the registry" do
  it "stop a read-only tool, which otherwise never reaches the gate" do
    registry = Smith::Tools::Registry.default(rule_approver(deny: ["read_file(**/.ssh/**)"]))

    result = registry.execute_calls([
      Smith::Tools::CallRequest.new("1", "read_file", JSON.parse(%({"path": "/Users/x/.ssh/id_rsa"}))),
    ]).first

    result.is_error.should be_true
    result.text.not_nil!.should contain("read_file(**/.ssh/**)")
  end

  it "leave untouched read tools on the fast path" do
    spy = SpyApprover.new(false)
    registry = Smith::Tools::Registry.default(rule_approver(inner: spy, deny: ["bash(rm *)"]))

    result = registry.execute_calls([
      Smith::Tools::CallRequest.new("1", "glob", JSON.parse(%({"pattern": "*.md"}))),
    ]).first

    result.is_error.should be_false
    spy.asked.should eq(0), "a read-only tool with no rules against it was sent to the approver"
  end

  it "are inherited by subagents along with the approver" do
    supervisor = Smith::Subagents::Supervisor.new(rule_approver(deny: ["bash(rm -rf *)"]))

    supervisor.approver.approve?(Smith::Tools::Bash.new, bash_call("rm -rf /")).should be_false
  end
end

describe "the always-allow prompt" do
  it "offers the narrowest rule instead of the whole tool" do
    output = IO::Memory.new
    prompt = Smith::Tools::PromptApprover.new(
      input: IO::Memory.new("a\n"),
      output: output,
      rules: Smith::Tools::RuleSet.build(project_dir: "/project")
    )

    prompt.approve?(Smith::Tools::Bash.new, bash_call("npm run build")).should be_true
    output.to_s.should contain("bash(npm run *)")
  end

  it "remembers that rule, not the tool name" do
    prompt = Smith::Tools::PromptApprover.new(
      input: IO::Memory.new("a\nn\n"),
      output: IO::Memory.new,
      rules: Smith::Tools::RuleSet.build(project_dir: "/project")
    )

    prompt.approve?(Smith::Tools::Bash.new, bash_call("npm run build")).should be_true
    # Covered by the remembered bash(npm run *) — not asked again.
    prompt.approve?(Smith::Tools::Bash.new, bash_call("npm run test")).should be_true
    # Outside it, so the next answer (n) applies.
    prompt.approve?(Smith::Tools::Bash.new, bash_call("git push")).should be_false
  end
end
