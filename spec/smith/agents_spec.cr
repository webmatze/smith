require "../spec_helper"
require "../../src/smith/agents"

# Writes agent definitions into a throwaway workspace and its isolated
# SMITH_HOME, so the developer's real ~/.smith is never read.
private def with_agents(project : Hash(String, String) = {} of String => String, global : Hash(String, String) = {} of String => String, &)
  temp_dir = File.join(Dir.tempdir, "smith_agents_#{Random::Secure.hex(4)}")
  home = File.join(temp_dir, "smith-home")

  project_dir = File.join(temp_dir, ".smith", "agents")
  global_dir = File.join(home, "agents")
  FileUtils.mkdir_p(project_dir)
  FileUtils.mkdir_p(global_dir)

  project.each { |name, content| File.write(File.join(project_dir, "#{name}.md"), content) }
  global.each { |name, content| File.write(File.join(global_dir, "#{name}.md"), content) }

  previous = ENV["SMITH_HOME"]?
  ENV["SMITH_HOME"] = home
  begin
    yield temp_dir
  ensure
    previous ? (ENV["SMITH_HOME"] = previous) : ENV.delete("SMITH_HOME")
    remove_tree(temp_dir)
  end
end

private REVIEWER = <<-MD
  ---
  name: reviewer
  description: Reviews a diff for correctness.
  tools: read_file, grep, glob
  model: claude-sonnet-5
  provider: anthropic
  mode: inspect
  ---
  You are a code reviewer for a Crystal project.
  MD

describe Smith::Agents::Catalog do
  it "reads every field from the frontmatter" do
    with_agents(project: {"reviewer" => REVIEWER}) do |dir|
      agent = Smith::Agents::Catalog.discover(dir).agents["reviewer"]

      agent.name.should eq("reviewer")
      agent.description.should eq("Reviews a diff for correctness.")
      agent.tools.should eq(["read_file", "grep", "glob"])
      agent.model.should eq("claude-sonnet-5")
      agent.provider.should eq("anthropic")
      agent.mode.should eq(Smith::Subagents::Mode::Inspect)
      agent.system_prompt.should eq("You are a code reviewer for a Crystal project.")
    end
  end

  it "finds both project and global agents" do
    with_agents(
      project: {"reviewer" => REVIEWER},
      global: {"researcher" => "---\ndescription: Researches things.\n---\nYou research."}
    ) do |dir|
      Smith::Agents::Catalog.discover(dir).agents.keys.sort.should eq(["researcher", "reviewer"])
    end
  end

  it "lets the project win on a name clash" do
    with_agents(
      project: {"reviewer" => "---\ndescription: project version\n---\nP"},
      global: {"reviewer" => "---\ndescription: global version\n---\nG"}
    ) do |dir|
      Smith::Agents::Catalog.discover(dir).agents["reviewer"].description.should eq("project version")
    end
  end

  it "defaults the name to the filename and the mode to work" do
    warnings = IO::Memory.new
    with_agents(project: {"tester" => "---\ndescription: Runs tests.\n---\nYou run tests."}) do |dir|
      agent = Smith::Agents::Catalog.discover(dir, warn_io: warnings).agents["tester"]

      agent.name.should eq("tester")
      agent.mode.should eq(Smith::Subagents::Mode::Work)
      agent.tools.should be_nil
      agent.model.should be_nil
      # A file that declares no mode is not a file that got one wrong: the
      # documented default has to stay silent, or the warning means nothing.
      agent.declared_mode.should be_nil
      agent.mode_fallback?.should be_false
      agent.mode_label.should eq("work")
      warnings.to_s.should be_empty
    end
  end

  it "takes a file without frontmatter as one big system prompt" do
    with_agents(project: {"bare" => "You are a bare agent."}) do |dir|
      agent = Smith::Agents::Catalog.discover(dir).agents["bare"]

      agent.name.should eq("bare")
      agent.system_prompt.should eq("You are a bare agent.")
    end
  end

  it "loads an agent with no description, but says so" do
    warnings = IO::Memory.new
    with_agents(project: {"nameless" => "You do things."}) do |dir|
      catalog = Smith::Agents::Catalog.discover(dir, warn_io: warnings)

      catalog.agents["nameless"]?.should_not be_nil
      warnings.to_s.should contain("nameless")
      warnings.to_s.should contain("description")
    end
  end

  it "says so when a definition's frontmatter did not read" do
    warnings = IO::Memory.new
    with_agents(project: {"broken" => "---\nname: deploy\ndescription: Ships the branch.\n\nYou deploy."}) do |dir|
      catalog = Smith::Agents::Catalog.discover(dir, warn_io: warnings)

      # The declared name never arrived, so the filename is all there is.
      catalog.agents["broken"]?.should_not be_nil
      catalog.agents["deploy"]?.should be_nil
      warnings.to_s.should contain("broken")
      warnings.to_s.should contain("frontmatter")
    end
  end

  # The catalog is built in the CLI's constructor, so a file that raises here
  # takes every smith command with it.
  it "warns and skips a definition that is not valid UTF-8" do
    warnings = IO::Memory.new
    with_agents do |dir|
      File.write(File.join(dir, ".smith", "agents", "latin1.md"), Bytes[0x2d, 0x2d, 0x2d, 0x0a, 0xff, 0xfe, 0x0a])

      catalog = Smith::Agents::Catalog.discover(dir, warn_io: warnings)

      catalog.agents.should be_empty
      warnings.to_s.should contain("not valid UTF-8")
    end
  end

  # Asking what the entry is raises here, so the guard has to sit around the
  # stat, not around the read.
  it "warns and skips a definition that is a symlink loop" do
    warnings = IO::Memory.new
    with_agents do |dir|
      File.symlink("aloop.md", File.join(dir, ".smith", "agents", "aloop.md"))

      catalog = Smith::Agents::Catalog.discover(dir, warn_io: warnings)

      catalog.agents.should be_empty
      warnings.to_s.should contain("aloop.md")
      warnings.to_s.should contain("could not be read")
    end
  end

  it "warns and skips a definition that is a directory" do
    warnings = IO::Memory.new
    with_agents do |dir|
      FileUtils.mkdir_p(File.join(dir, ".smith", "agents", "folder.md"))

      catalog = Smith::Agents::Catalog.discover(dir, warn_io: warnings)

      catalog.agents.should be_empty
      warnings.to_s.should contain("not a regular file (directory)")
    end
  end

  it "ignores anything that is not a .md file" do
    with_agents(project: {"reviewer" => REVIEWER}) do |dir|
      File.write(File.join(dir, ".smith", "agents", "notes.txt"), "not an agent")

      Smith::Agents::Catalog.discover(dir).agents.keys.should eq(["reviewer"])
    end
  end

  it "has nothing to say when there are no agents" do
    with_agents do |dir|
      catalog = Smith::Agents::Catalog.discover(dir)

      catalog.agents.should be_empty
      catalog.summary_prompt.should be_nil
    end
  end

  it "lists the agents for the tool description" do
    with_agents(project: {"reviewer" => REVIEWER}) do |dir|
      summary = Smith::Agents::Catalog.discover(dir).summary_prompt.not_nil!

      summary.should contain("reviewer")
      summary.should contain("Reviews a diff for correctness.")
    end
  end
end

describe "the tools an agent definition resolves to" do
  it "uses its own list when given one" do
    with_agents(project: {"reviewer" => REVIEWER}) do |dir|
      Smith::Agents::Catalog.discover(dir).agents["reviewer"]
        .tool_names.should eq(["read_file", "grep", "glob"])
    end
  end

  it "falls back to the read-only set for inspect mode" do
    with_agents(project: {"a" => "---\ndescription: d\nmode: inspect\n---\nP"}) do |dir|
      names = Smith::Agents::Catalog.discover(dir).agents["a"].tool_names

      names.should contain("read_file")
      names.should_not contain("bash")
      names.should_not contain("write_file")
    end
  end

  it "falls back to the full set for work mode" do
    with_agents(project: {"a" => "---\ndescription: d\n---\nP"}) do |dir|
      names = Smith::Agents::Catalog.discover(dir).agents["a"].tool_names

      names.should contain("bash")
      names.should contain("write_file")
    end
  end
end

# `mode:` is the one field in a definition that is a security statement, and an
# unreadable value used to resolve to `work` — the full tool set, silently, for
# a file whose author wrote the opposite. The typo costs the agent tools now,
# rather than costing the reader the promise.
describe "an agent definition with a mode smith cannot read" do
  it "warns with the path and the value, and falls back to inspect" do
    warnings = IO::Memory.new
    with_agents(project: {"auditor" => "---\ndescription: Audits.\nmode: inspekt\n---\nP"}) do |dir|
      agent = Smith::Agents::Catalog.discover(dir, warn_io: warnings).agents["auditor"]

      agent.mode.should eq(Smith::Subagents::Mode::Inspect)
      agent.tool_names.should_not contain("bash")
      agent.tool_names.should_not contain("write_file")
      agent.tool_names.should_not contain("edit_file")

      warnings.to_s.should contain("inspekt")
      warnings.to_s.should contain(File.join(dir, ".smith", "agents", "auditor.md"))
      warnings.to_s.should contain("inspect")
    end
  end

  # The definition is not rejected: an unreadable mode should make an agent
  # careful, not unusable.
  it "keeps the definition, with everything else it declared" do
    with_agents(project: {"auditor" => "---\ndescription: Audits.\nmode: read-only\nmodel: m\n---\nThe prompt."}) do |dir|
      agent = Smith::Agents::Catalog.discover(dir, warn_io: IO::Memory.new).agents["auditor"]

      agent.description.should eq("Audits.")
      agent.model.should eq("m")
      agent.system_prompt.should eq("The prompt.")
    end
  end

  # The second half of the issue: `smith agents list` prints `mode_label`, and
  # the view that exists to make configuration visible must not pass smith's own
  # fallback off as the author's configuration.
  it "marks the fallback as a fallback where the listing reads the mode" do
    with_agents(project: {"auditor" => "---\ndescription: Audits.\nmode: inspekt\n---\nP"}) do |dir|
      agent = Smith::Agents::Catalog.discover(dir, warn_io: IO::Memory.new).agents["auditor"]

      agent.declared_mode.should eq("inspekt")
      agent.mode_fallback?.should be_true
      agent.mode_label.should contain("inspect")
      agent.mode_label.should contain("fallback")
      agent.mode_label.should contain("inspekt")
    end
  end

  it "reads a declared mode back as itself, whatever its case" do
    warnings = IO::Memory.new
    with_agents(project: {
      "loud"   => "---\ndescription: d\nmode: Inspect\n---\nP",
      "louder" => "---\ndescription: d\nmode: WORK\n---\nP",
    }) do |dir|
      catalog = Smith::Agents::Catalog.discover(dir, warn_io: warnings)

      catalog.agents["loud"].mode.should eq(Smith::Subagents::Mode::Inspect)
      catalog.agents["loud"].mode_fallback?.should be_false
      catalog.agents["loud"].mode_label.should eq("inspect")
      catalog.agents["louder"].mode.should eq(Smith::Subagents::Mode::Work)
      catalog.agents["louder"].mode_fallback?.should be_false
      warnings.to_s.should be_empty
    end
  end

  # `mode:` with nothing after it is "configured as empty", which the header
  # parser hands back as no value at all — the documented default, not a typo.
  it "treats an empty mode as none at all" do
    warnings = IO::Memory.new
    with_agents(project: {"blank" => "---\ndescription: d\nmode:\n---\nP"}) do |dir|
      agent = Smith::Agents::Catalog.discover(dir, warn_io: warnings).agents["blank"]

      agent.mode.should eq(Smith::Subagents::Mode::Work)
      agent.mode_fallback?.should be_false
      warnings.to_s.should_not contain("is not a mode")
    end
  end
end

# Global is read first, so a project definition of the same name replaces it. A
# warning that names the file which lost, without saying it lost, reads as "the
# agent you are using is broken".
describe "agent definitions that shadow each other" do
  it "names the file in effect when the broken one is the one that lost" do
    warnings = IO::Memory.new
    with_agents(
      project: {"dup" => "---\nname: dup\ndescription: The good one.\n---\nP"},
      global: {"dup" => "---\nname: dup\ndescription: The broken one.\n\nG"}
    ) do |dir|
      catalog = Smith::Agents::Catalog.discover(dir, warn_io: warnings)

      project_path = File.join(dir, ".smith", "agents", "dup.md")
      global_path = File.join(dir, "smith-home", "agents", "dup.md")

      catalog.agents["dup"].description.should eq("The good one.")
      catalog.agents["dup"].path.should eq(project_path)
      catalog.shadowed["dup"].should eq([global_path])

      warnings.to_s.should contain(global_path)
      warnings.to_s.should contain("comes from #{project_path}")
    end
  end

  it "claims no such thing when the broken file is the one in effect" do
    warnings = IO::Memory.new
    with_agents(
      project: {"dup" => "---\nname: dup\ndescription: The broken one.\n\nP"},
      global: {"dup" => "---\nname: dup\ndescription: The good one.\n---\nG"}
    ) do |dir|
      catalog = Smith::Agents::Catalog.discover(dir, warn_io: warnings)

      project_path = File.join(dir, ".smith", "agents", "dup.md")
      global_path = File.join(dir, "smith-home", "agents", "dup.md")

      catalog.agents["dup"].path.should eq(project_path)
      warnings.to_s.should contain(project_path)
      warnings.to_s.should_not contain("comes from")
      # The file that lost is still accounted for, so the listing can show it.
      catalog.shadowed["dup"].should eq([global_path])
    end
  end
end
