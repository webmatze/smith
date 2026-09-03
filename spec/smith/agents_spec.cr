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
    FileUtils.rm_rf(temp_dir) if Dir.exists?(temp_dir)
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
    with_agents(project: {"tester" => "---\ndescription: Runs tests.\n---\nYou run tests."}) do |dir|
      agent = Smith::Agents::Catalog.discover(dir).agents["tester"]

      agent.name.should eq("tester")
      agent.mode.should eq(Smith::Subagents::Mode::Work)
      agent.tools.should be_nil
      agent.model.should be_nil
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
