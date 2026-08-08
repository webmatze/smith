require "../../spec_helper"
require "../../../src/smith/tools/permissions"

private def rules(allow = [] of String, ask = [] of String, deny = [] of String, project_dir = "/project")
  Smith::Tools::RuleSet.build(allow: allow, ask: ask, deny: deny, project_dir: project_dir)
end

private def bash_call(command : String)
  Smith::Tools::CallRequest.new("1", "bash", JSON.parse({"command" => command}.to_json))
end

private def path_call(tool : String, path : String)
  Smith::Tools::CallRequest.new("1", tool, JSON.parse({"path" => path}.to_json))
end

# An MCP tool takes whatever arguments its server defines, so there is nothing
# smith could sensibly match in parentheses — the tool name carries the whole
# rule, which is the form every other MCP client writes too. The path argument
# is there to prove it is *not* consulted.
private def mcp_call(tool : String)
  Smith::Tools::CallRequest.new("1", tool, JSON.parse(%({"path": "/etc/passwd"})))
end

private def with_project(&)
  root = File.realpath(Dir.tempdir)
  project = File.join(root, "smith_perm_#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(File.join(project, "src"))
  begin
    yield project
  ensure
    FileUtils.rm_rf(project) if Dir.exists?(project)
  end
end

describe Smith::Tools::Rule do
  it "parses the tool(pattern) form" do
    rule = Smith::Tools::Rule.parse("bash(git *)").not_nil!

    rule.tool.should eq("bash")
    rule.pattern.should eq("git *")
  end

  it "tolerates whitespace and nested parentheses in the pattern" do
    Smith::Tools::Rule.parse("  bash( echo $(date) ) ").not_nil!.pattern.should eq("echo $(date)")
  end

  it "returns nil for a malformed rule rather than raising" do
    Smith::Tools::Rule.parse("bash(unclosed").should be_nil
    Smith::Tools::Rule.parse("no-parens").should be_nil
    Smith::Tools::Rule.parse("(empty-tool)").should be_nil
  end
end

describe "rule precedence" do
  it "puts deny above ask above allow" do
    set = rules(allow: ["bash(git *)"], ask: ["bash(git push *)"], deny: ["bash(git push --force *)"])

    set.decide("bash", bash_call("git status").args).should eq(Smith::Tools::Decision::Allow)
    set.decide("bash", bash_call("git push origin main").args).should eq(Smith::Tools::Decision::Ask)
    set.decide("bash", bash_call("git push --force origin main").args).should eq(Smith::Tools::Decision::Deny)
  end

  it "leaves anything unmatched to the configured mode" do
    rules(allow: ["bash(git *)"]).decide("bash", bash_call("npm test").args)
      .should eq(Smith::Tools::Decision::Unset)
  end
end

describe "bash patterns" do
  it "matches a bare prefix, with or without further arguments" do
    set = rules(allow: ["bash(git status)"])

    set.decide("bash", bash_call("git status").args).should eq(Smith::Tools::Decision::Allow)
    set.decide("bash", bash_call("git status --short").args).should eq(Smith::Tools::Decision::Allow)
    set.decide("bash", bash_call("git statuses").args).should eq(Smith::Tools::Decision::Unset)
  end

  it "supports a wildcard at any position" do
    rules(allow: ["bash(git *)"]).decide("bash", bash_call("git push origin main").args)
      .should eq(Smith::Tools::Decision::Allow)
    rules(allow: ["bash(* install)"]).decide("bash", bash_call("npm install").args)
      .should eq(Smith::Tools::Decision::Allow)
    rules(allow: ["bash(* install)"]).decide("bash", bash_call("bundle install --path vendor").args)
      .should eq(Smith::Tools::Decision::Allow)
    rules(allow: ["bash(npm run *)"]).decide("bash", bash_call("npm run build").args)
      .should eq(Smith::Tools::Decision::Allow)
  end

  it "requires every segment to match before allowing" do
    # The whole point of the existing segmentation: an allowed prefix must not
    # smuggle a second command in behind it.
    rules(allow: ["bash(git *)"]).decide("bash", bash_call("git status; rm -rf /").args)
      .should eq(Smith::Tools::Decision::Unset)
  end

  it "denies when any single segment matches" do
    # The mirror image, and the security-relevant half: a denied command must
    # not become allowed by hiding behind a harmless one.
    set = rules(allow: ["bash(*)"], deny: ["bash(rm -rf *)"])

    set.decide("bash", bash_call("ls && rm -rf /").args).should eq(Smith::Tools::Decision::Deny)
    set.decide("bash", bash_call("ls").args).should eq(Smith::Tools::Decision::Allow)
  end

  it "treats a bare wildcard as everything" do
    rules(allow: ["bash(*)"]).decide("bash", bash_call("anything at all").args)
      .should eq(Smith::Tools::Decision::Allow)
  end
end

describe "path patterns" do
  it "scopes a rule to a subtree" do
    with_project do |project|
      set = rules(allow: ["write_file(src/**)"], project_dir: project)

      set.decide("write_file", path_call("write_file", "src/foo.cr").args)
        .should eq(Smith::Tools::Decision::Allow)
      set.decide("write_file", path_call("write_file", "docs/foo.md").args)
        .should eq(Smith::Tools::Decision::Unset)
    end
  end

  it "does not let .. escape the scope" do
    with_project do |project|
      set = rules(allow: ["write_file(src/**)"], project_dir: project)

      set.decide("write_file", path_call("write_file", "src/../../../etc/passwd").args)
        .should eq(Smith::Tools::Decision::Unset)
    end
  end

  it "resolves a symlink pointing out of the scope" do
    with_project do |project|
      outside = File.join(project, "outside")
      FileUtils.mkdir_p(outside)
      File.write(File.join(outside, "secret.txt"), "s")
      File.symlink(outside, File.join(project, "src", "link"))

      set = rules(allow: ["write_file(src/**)"], project_dir: project)

      # Textually inside src/, actually not.
      set.decide("write_file", path_call("write_file", "src/link/secret.txt").args)
        .should eq(Smith::Tools::Decision::Unset)
    end
  end

  it "normalises a path whose file does not exist yet" do
    with_project do |project|
      set = rules(allow: ["write_file(src/**)"], project_dir: project)

      set.decide("write_file", path_call("write_file", "src/brand/new/file.cr").args)
        .should eq(Smith::Tools::Decision::Allow)
    end
  end

  it "matches an absolute path against an unanchored pattern" do
    set = rules(deny: ["read_file(**/.ssh/**)"], project_dir: "/project")

    set.decide("read_file", path_call("read_file", "/Users/someone/.ssh/id_rsa").args)
      .should eq(Smith::Tools::Decision::Deny)
  end

  it "anchors a relative pattern to the project" do
    with_project do |project|
      set = rules(deny: ["write_file(.env*)"], project_dir: project)

      set.decide("write_file", path_call("write_file", ".env.local").args)
        .should eq(Smith::Tools::Decision::Deny)
      set.decide("write_file", path_call("write_file", "src/foo.cr").args)
        .should eq(Smith::Tools::Decision::Unset)
    end
  end

  it "treats a bare wildcard as every path" do
    rules(allow: ["read_file(**)"]).decide("read_file", path_call("read_file", "/anywhere/at/all").args)
      .should eq(Smith::Tools::Decision::Allow)
  end

  it "ignores rules for a different tool" do
    rules(deny: ["write_file(**)"]).decide("read_file", path_call("read_file", "/x").args)
      .should eq(Smith::Tools::Decision::Unset)
  end
end

describe "MCP tool rules" do
  it "parses a bare wildcard tool name" do
    rule = Smith::Tools::Rule.parse("mcp__filesystem__*").not_nil!
    rule.tool.should eq("mcp__filesystem__*")
    rule.wildcard?.should be_true
    rule.to_s.should eq("mcp__filesystem__*")
  end

  it "covers every tool of one server" do
    set = rules(allow: ["mcp__filesystem__*"])

    set.decide("mcp__filesystem__read_file", mcp_call("mcp__filesystem__read_file").args).should eq(Smith::Tools::Decision::Allow)
    set.decide("mcp__filesystem__write_file", mcp_call("mcp__filesystem__write_file").args).should eq(Smith::Tools::Decision::Allow)
  end

  # Anchored at both ends: a rule for one server must not reach a differently
  # named one that merely starts the same way.
  it "does not leak into another server" do
    set = rules(allow: ["mcp__fs__*"])
    set.decide("mcp__fs_admin__delete", mcp_call("mcp__fs_admin__delete").args).should eq(Smith::Tools::Decision::Unset)
  end

  it "lets deny beat a wildcard allow" do
    set = rules(allow: ["mcp__db__*"], deny: ["mcp__db__drop_table"])

    set.decide("mcp__db__query", mcp_call("mcp__db__query").args).should eq(Smith::Tools::Decision::Allow)
    set.decide("mcp__db__drop_table", mcp_call("mcp__db__drop_table").args).should eq(Smith::Tools::Decision::Deny)
  end

  it "names a single MCP tool without a wildcard" do
    rules(allow: ["mcp__db__query"])
      .decide("mcp__db__query", mcp_call("mcp__db__query").args).should eq(Smith::Tools::Decision::Allow)
  end

  # The tool's own `path` argument is not a rule pattern, so remembering one
  # would quietly widen the answer to every path under it.
  it "suggests the bare tool name for [a]lways" do
    rules.suggest("mcp__fs__read", mcp_call("mcp__fs__read").args).should eq("mcp__fs__read")
  end

  it "reports a wildcard rule as governing the tools it covers" do
    set = rules(deny: ["mcp__db__*"])
    set.governs?("mcp__db__query").should be_true
    set.governs?("mcp__other__query").should be_false
  end

  # A bare name without a wildcard would silently widen a path rule to
  # everything, which is not what anyone writing `read_file` means.
  it "still rejects a bare name that is not a wildcard" do
    Smith::Tools::Rule.parse("read_file").should be_nil
  end
end

describe "which tools the rules govern" do
  it "reports the tools that a deny or ask rule can act on" do
    set = rules(allow: ["read_file(**)"], deny: ["read_file(**/.ssh/**)"], ask: ["edit_file(**)"])

    # These have to reach the gate even though they are not mutating.
    set.governs?("read_file").should be_true
    set.governs?("edit_file").should be_true
    # Allow-only rules never need to stop anything.
    set.governs?("glob").should be_false
  end

  it "reports nothing when there are no rules at all" do
    rules.governs?("read_file").should be_false
    rules.empty?.should be_true
  end
end

describe "the rule suggested for [a]lways" do
  it "generalises the last word of a shell command" do
    set = rules
    set.suggest("bash", bash_call("npm run build").args).should eq("bash(npm run *)")
    set.suggest("bash", bash_call("git status").args).should eq("bash(git *)")
  end

  it "keeps a single-word command exact" do
    rules.suggest("bash", bash_call("ls").args).should eq("bash(ls)")
  end

  it "offers the containing directory for a path tool" do
    with_project do |project|
      set = rules(project_dir: project)

      set.suggest("write_file", path_call("write_file", "src/deep/foo.cr").args)
        .should eq("write_file(src/deep/**)")
    end
  end

  it "falls back to the tool itself when there is nothing to generalise" do
    rules.suggest("glob", JSON.parse("{}")).should eq("glob(**)")
  end
end

describe "malformed rules" do
  it "are skipped with a warning instead of taking smith down" do
    warnings = IO::Memory.new
    set = Smith::Tools::RuleSet.build(
      allow: ["bash(unclosed", "bash(ls)"],
      project_dir: "/project",
      warn_io: warnings
    )

    set.decide("bash", bash_call("ls").args).should eq(Smith::Tools::Decision::Allow)
    warnings.to_s.should contain("bash(unclosed")
  end
end

describe "a project reached through a symlink" do
  # Paths are normalised before matching, so the project directory has to be
  # too, or every relative rule silently stops matching. This is not exotic:
  # on macOS /tmp is a symlink to /private/tmp, and a shell's `cd` leaves
  # Dir.current unresolved.
  it "still matches relative allow and deny rules" do
    with_project do |project|
      link = File.join(Dir.tempdir, "smith_perm_link_#{Random::Secure.hex(4)}")
      File.symlink(project, link)

      begin
        set = rules(
          allow: ["write_file(src/**)"],
          deny: ["write_file(.env*)"],
          project_dir: link
        )

        set.decide("write_file", path_call("write_file", "src/foo.cr").args)
          .should eq(Smith::Tools::Decision::Allow)
        set.decide("write_file", path_call("write_file", ".env.local").args)
          .should eq(Smith::Tools::Decision::Deny)
      ensure
        File.delete(link) if File.symlink?(link)
      end
    end
  end

  it "suggests a rule relative to the project, not to its resolved twin" do
    with_project do |project|
      link = File.join(Dir.tempdir, "smith_perm_link_#{Random::Secure.hex(4)}")
      File.symlink(project, link)

      begin
        rules(project_dir: link).suggest("write_file", path_call("write_file", "src/foo.cr").args)
          .should eq("write_file(src/**)")
      ensure
        File.delete(link) if File.symlink?(link)
      end
    end
  end
end
