require "../spec_helper"
require "../../src/smith/doctor"
require "../../src/smith/skills"
require "../../src/smith/agents"

# Where this PR and `smith doctor` overlap.
#
# #104 kept both catalogs' problems non-consuming so the doctor does not have to
# walk them a second time, and this PR must not take that away: a definition the
# reader wrote must still reach the Environment block even though `report` has
# already said it on stderr.
#
# What the doctor *renders* is a different question, and the answer is the same
# distinction that fixed the startup noise, applied to volume rather than
# channel: the reader's own files in full, because those are what a diagnosis
# can tell them to go and fix, and a plugin's counted by reason, because they
# did not write them and eighteen copies of one sentence buries the findings
# the command exists for.
private def with_tree(project : Hash(String, String), plugin : Hash(String, String), &)
  temp_dir = File.join(Dir.tempdir, "smith_doctor_plugins_#{Random::Secure.hex(6)}")
  home = File.join(temp_dir, "smith-home")
  FileUtils.mkdir_p(home)

  project.each do |name, content|
    dir = File.join(temp_dir, ".smith", "agents")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{name}.md"), content)
  end

  plugin.each do |relative, content|
    path = File.join(home, "plugins", "installed", "mkt", "p", relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  previous = ENV["SMITH_HOME"]?
  ENV["SMITH_HOME"] = home
  begin
    yield temp_dir
  ensure
    previous ? (ENV["SMITH_HOME"] = previous) : ENV.delete("SMITH_HOME")
    remove_tree(temp_dir)
  end
end

describe "smith doctor and the plugin catalogs" do
  it "still sees a definition the reader wrote, after report has said it" do
    with_tree(
      project: {"mine" => "---\nname: mine\n---\nNo description here."},
      plugin: {"agents/theirs.md" => "---\nname: theirs\ndescription: d\nmaxTurns: 9\n---\nprompt"}
    ) do |dir|
      startup = IO::Memory.new
      agents = Smith::Agents::Catalog.discover(workspace_dir: dir, warn_io: startup)
      skills = Smith::Skills::Catalog.discover(workspace_dir: dir, warn_io: IO::Memory.new)

      # Startup says only what the reader owns.
      startup.to_s.should contain("Agent 'mine'")
      startup.to_s.should_not contain("p:theirs")

      # The reader's own file is spelled out; the plugin's is counted, not
      # quoted. Both are accounted for.
      notes = Smith::Doctor.catalog_notes(skills, agents)
      notes.count { |line| line.includes?("Agent 'mine'") }.should eq(1)
      notes.any?(&.includes?("p:theirs")).should be_false
      notes.any? { |line| line.includes?("1 plugin agent in 1 plugin") && line.includes?("maxTurns") }.should be_true
    end
  end

  # Three real marketplaces put thirty lines about other people's plugins into
  # this block, eighteen of them the same sentence, burying the findings the
  # command exists for. Volume, not channel — but the same distinction fixes it.
  it "collapses many plugin files sharing one reason into a single finding" do
    broken = "---\nname: %s\ndescription: d\ntools:\n  - read_file\n---\nbody"
    plugin_files = {} of String => String

    # Eighteen skills in one plugin, all with the same unreadable header.
    18.times do |i|
      plugin_files["skills/s#{i}/SKILL.md"] = broken % "s#{i}"
    end

    with_tree(
      project: {"mine" => "---\nname: mine\n---\nNo description here."},
      plugin: plugin_files
    ) do |dir|
      skills = Smith::Skills::Catalog.discover(workspace_dir: dir, warn_io: IO::Memory.new)
      agents = Smith::Agents::Catalog.discover(workspace_dir: dir, warn_io: IO::Memory.new)

      # The full detail is still there for anyone who asks for it.
      skills.warnings.size.should eq(18)

      notes = Smith::Doctor.catalog_notes(skills, agents)
      summary = notes.select(&.includes?("plugin skill"))
      summary.size.should eq(1)
      summary.first.should contain("18 plugin skills in 1 plugin:")
      summary.first.should contain("smith skills list")

      # The reader's own broken definition is still spelled out in full…
      notes.any?(&.includes?("Agent 'mine'")).should be_true
      # …and the block did not grow with the plugin count.
      notes.size.should eq(2)

      # The status logic is untouched: still a warning, never a failure.
      check = Smith::Doctor.environment_check(
        home: dir, home_overridden: true, global_instructions: nil,
        project_instructions: Array(String).new,
        skills: skills.skills.size, agents: agents.agents.size, catalog_notes: notes)
      check.status.warn?.should be_true
    end
  end

  it "counts a plugin's skills and agents like any other" do
    with_tree(
      project: {} of String => String,
      plugin: {
        "skills/alpha/SKILL.md" => "---\nname: alpha\ndescription: d\n---\nbody",
        "agents/auditor.md"     => "---\nname: auditor\ndescription: d\n---\nprompt",
      }
    ) do |dir|
      skills = Smith::Skills::Catalog.discover(workspace_dir: dir, warn_io: IO::Memory.new)
      agents = Smith::Agents::Catalog.discover(workspace_dir: dir, warn_io: IO::Memory.new)

      skills.skills.keys.should eq(["p:alpha"])
      agents.agents.keys.should eq(["p:auditor"])
      Smith::Doctor.catalog_notes(skills, agents).should be_empty
    end
  end
end
