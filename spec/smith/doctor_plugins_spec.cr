require "../spec_helper"
require "../../src/smith/doctor"
require "../../src/smith/skills"
require "../../src/smith/agents"

# Where this PR and `smith doctor` overlap.
#
# `Doctor.catalog_notes` is `skills.warnings + agents.warnings`, and #104 kept
# both non-consuming so the doctor does not have to walk the catalogs a second
# time. Splitting the agents catalog's output between a startup channel and a
# listing had to leave that view **complete** — a definition the reader wrote
# that smith could not read must still reach the Environment block, even though
# `report` has already said it on stderr.
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

      # The doctor's view is the complete one, both before and after.
      notes = Smith::Doctor.catalog_notes(skills, agents).join("\n")
      notes.should contain("Agent 'mine'")
      notes.should contain("p:theirs")
      notes.should contain("smith does not act on maxTurns")
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
