require "../../spec_helper"
require "../../../src/smith/tools"
require "../../../src/smith/tools/sandbox_approver"

private def bash_call(command : String) : Smith::Tools::CallRequest
  Smith::Tools::CallRequest.new("c1", "bash", JSON.parse(%({"command": #{command.to_json}})))
end

private def bash_tool : Smith::Tools::Bash
  Smith::Tools::Bash.new
end

# Confines everything except what it was told to excuse — enough to drive the
# approver without a real profile or a real kernel.
private class FakeSandbox < Smith::Sandbox::Strategy
  def initialize(@excused : Array(String) = [] of String)
  end

  def name : String
    "fake"
  end

  def active? : Bool
    true
  end

  def sandboxed?(command : String) : Bool
    !Smith::Tools::AllowList.allows?(command, @excused)
  end

  def wrap(command : String) : Tuple(String, Array(String))
    {"/bin/bash", ["-c", command]}
  end

  def describe : String
    "fake"
  end
end

describe Smith::Tools::SandboxApprover do
  it "lets a confined command through without asking" do
    approver = Smith::Tools::SandboxApprover.new(FakeSandbox.new, Smith::Tools::DenyApprover.new)

    approver.approve?(bash_tool, bash_call("rm -rf build")).should be_true
  end

  it "asks about a command that was excused from the sandbox" do
    # It runs with full rights, so it is exactly the command that still needs
    # a human — the opposite of what the name might suggest.
    approver = Smith::Tools::SandboxApprover.new(
      FakeSandbox.new(["git push"]),
      Smith::Tools::DenyApprover.new
    )

    approver.approve?(bash_tool, bash_call("git push origin main")).should be_false
  end

  it "does not cover write_file, which never enters the sandbox" do
    # write_file runs inside smith's own process. Waving it through would
    # claim a protection that was never switched on for it.
    approver = Smith::Tools::SandboxApprover.new(FakeSandbox.new, Smith::Tools::DenyApprover.new)

    approver.approve?(
      Smith::Tools::WriteFile.new,
      Smith::Tools::CallRequest.new("c1", "write_file", JSON.parse(%({"path": "/etc/hosts"})))
    ).should be_false
  end

  it "falls through when there is no command to judge" do
    approver = Smith::Tools::SandboxApprover.new(FakeSandbox.new, Smith::Tools::DenyApprover.new)

    approver.approve?(bash_tool, Smith::Tools::CallRequest.new("c1", "bash", JSON.parse("{}"))).should be_false
  end

  describe "inside the approver chain" do
    it "loses to a deny rule" do
      # The order of authority is the point: confinement decides what a
      # command *can* do, a deny rule decides what it *may* do, and the rule
      # is consulted first.
      rules = Smith::Tools::RuleSet.build(
        allow: [] of String,
        ask: [] of String,
        deny: ["bash(rm *)"],
        project_dir: Dir.current
      )
      approver = Smith::Tools::RuleApprover.new(
        rules,
        Smith::Tools::SandboxApprover.new(FakeSandbox.new, Smith::Tools::DenyApprover.new)
      )

      approver.approve?(bash_tool, bash_call("rm -rf build")).should be_false
      approver.denial_message(bash_tool, bash_call("rm -rf build")).should contain("deny rule")
    end

    it "still frees an unruled command" do
      rules = Smith::Tools::RuleSet.build(
        allow: [] of String,
        ask: [] of String,
        deny: ["bash(rm *)"],
        project_dir: Dir.current
      )
      approver = Smith::Tools::RuleApprover.new(
        rules,
        Smith::Tools::SandboxApprover.new(FakeSandbox.new, Smith::Tools::DenyApprover.new)
      )

      approver.approve?(bash_tool, bash_call("make test")).should be_true
    end
  end
end
