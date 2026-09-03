require "../spec_helper"
require "../../src/smith/skills"

describe Smith::Skills::Catalog do
  it "discovers skills and expands $skill and /skill invocations" do
    temp_dir = File.join(Dir.tempdir, "smith_skill_test_#{Random::Secure.hex(4)}")
    skill_dir = File.join(temp_dir, ".smith", "skills", "test-runner")
    FileUtils.mkdir_p(skill_dir)

    skill_file = File.join(skill_dir, "SKILL.md")
    File.write(skill_file, "---\nname: test-runner\ndescription: Run crystal spec\n---\n\nRun 'crystal spec' to test everything.")

    # Isolate from the user's real global skills (~/.smith/skills) via SMITH_HOME
    prev_smith_home = ENV["SMITH_HOME"]?
    ENV["SMITH_HOME"] = File.join(temp_dir, "smith-home")

    begin
      catalog = Smith::Skills::Catalog.discover(workspace_dir: temp_dir)
      catalog.skills.size.should eq(1)
      catalog.skills["test-runner"]?.should_not be_nil

      summary = catalog.summary_prompt
      summary.should_not be_nil
      summary.not_nil!.should contain("test-runner")

      # Test $skill expansion
      expanded_dollar = catalog.expand_prompt("Please run $test-runner for me")
      expanded_dollar.should contain("Skill Context: test-runner")
      expanded_dollar.should contain("Run 'crystal spec' to test everything.")

      # Test /skill expansion
      expanded_slash = catalog.expand_prompt("/test-runner src/smith.cr")
      expanded_slash.should contain("Execute skill 'test-runner'")
      expanded_slash.should contain("Arguments: src/smith.cr")
      expanded_slash.should contain("Run 'crystal spec' to test everything.")
    ensure
      if prev = prev_smith_home
        ENV["SMITH_HOME"] = prev
      else
        ENV.delete("SMITH_HOME")
      end
      FileUtils.rm_rf(temp_dir) if Dir.exists?(temp_dir)
    end
  end
end

# The frontmatter parser is shared with agent definitions now, so these pin the
# behaviour skills relied on before the two were merged.
private def with_skill(content : String, dir_name : String = "example", &)
  temp_dir = File.join(Dir.tempdir, "smith_skill_fm_#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(File.join(temp_dir, ".smith", "skills", dir_name))
  File.write(File.join(temp_dir, ".smith", "skills", dir_name, "SKILL.md"), content)

  prev = ENV["SMITH_HOME"]?
  ENV["SMITH_HOME"] = File.join(temp_dir, "smith-home")
  begin
    yield Smith::Skills::Catalog.discover(workspace_dir: temp_dir)
  ensure
    prev ? (ENV["SMITH_HOME"] = prev) : ENV.delete("SMITH_HOME")
    FileUtils.rm_rf(temp_dir) if Dir.exists?(temp_dir)
  end
end

describe "skill frontmatter" do
  it "prefers the declared name over the directory name" do
    with_skill("---\nname: declared\ndescription: d\n---\nbody") do |catalog|
      catalog.skills.keys.should eq(["declared"])
    end
  end

  it "falls back to the directory name and a placeholder description" do
    with_skill("Just a body, no frontmatter.", dir_name: "from-dir") do |catalog|
      skill = catalog.skills["from-dir"]
      skill.description.should eq("No description provided.")
      skill.body.should eq("Just a body, no frontmatter.")
    end
  end
end

# A header that did not parse used to be invisible: the skill still loaded, but
# under the wrong name and without its description, and nothing said so.
describe "skill frontmatter warnings" do
  it "warns about a block that is never closed, and still loads the body" do
    with_skill("---\nname: deploy\ndescription: Ship the branch\n\nRun the deploy script.\n", dir_name: "deploy") do |catalog|
      catalog.warnings.size.should eq(1)
      catalog.warnings.first.should contain(File.join("deploy", "SKILL.md"))
      catalog.warnings.first.should contain("frontmatter")

      # The declared name never arrived, so the directory name is all there is.
      skill = catalog.skills["deploy"]
      skill.description.should eq("No description provided.")
      skill.body.should contain("Run the deploy script.")
    end
  end

  it "warns about a skill the model has nothing to choose by" do
    with_skill("---\nname: bare\n---\nbody", dir_name: "bare") do |catalog|
      catalog.warnings.size.should eq(1)
      catalog.warnings.first.should contain("no description")
      catalog.skills["bare"].body.should eq("body")
    end
  end

  it "stays quiet about a skill that reads fine" do
    with_skill("---\nname: ok\ndescription: Does a thing.\n---\nbody") do |catalog|
      catalog.warnings.should be_empty
    end
  end
end

# Writes SKILL.md files into a throwaway workspace and its isolated SMITH_HOME,
# and hands the workspace back rather than a catalog, so a spec can break a file
# before discovery runs.
private def with_skill_files(
  project : Hash(String, String) = {} of String => String,
  global : Hash(String, String) = {} of String => String,
  &
)
  temp_dir = File.join(Dir.tempdir, "smith_skill_cat_#{Random::Secure.hex(4)}")
  home = File.join(temp_dir, "smith-home")

  project.each { |name, content| write_skill_file(File.join(temp_dir, ".smith", "skills", name), content) }
  global.each { |name, content| write_skill_file(File.join(home, "skills", name), content) }

  previous = ENV["SMITH_HOME"]?
  ENV["SMITH_HOME"] = home
  begin
    yield temp_dir
  ensure
    previous ? (ENV["SMITH_HOME"] = previous) : ENV.delete("SMITH_HOME")
    FileUtils.rm_rf(temp_dir) if Dir.exists?(temp_dir)
  end
end

private def write_skill_file(dir : String, content : String) : String
  FileUtils.mkdir_p(dir)
  path = File.join(dir, "SKILL.md")
  File.write(path, content)
  path
end

private def project_skill_path(dir : String, name : String) : String
  File.join(dir, ".smith", "skills", name, "SKILL.md")
end

private def global_skill_path(dir : String, name : String) : String
  File.join(dir, "smith-home", "skills", name, "SKILL.md")
end

# Global is read first, so a project file of the same name replaces it. A
# warning that names the file which lost, without saying it lost, reads as
# "the skill you are using is broken".
describe "skills that shadow each other" do
  it "names the file in effect when the broken one is the one that lost" do
    with_skill_files(
      project: {"dup" => "---\nname: dup\ndescription: The good one.\n---\nproject body"},
      global: {"dup" => "---\nname: dup\ndescription: The broken one.\n\nglobal body"}
    ) do |dir|
      catalog = Smith::Skills::Catalog.discover(workspace_dir: dir)

      catalog.skills["dup"].description.should eq("The good one.")
      catalog.skills["dup"].path.should eq(project_skill_path(dir, "dup"))
      catalog.shadowed["dup"].should eq([global_skill_path(dir, "dup")])

      catalog.warnings.size.should eq(1)
      catalog.warnings.first.should contain(global_skill_path(dir, "dup"))
      catalog.warnings.first.should contain("comes from #{project_skill_path(dir, "dup")}")
    end
  end

  it "claims no such thing when the broken file is the one in effect" do
    with_skill_files(
      project: {"dup" => "---\nname: dup\ndescription: The broken one.\n\nproject body"},
      global: {"dup" => "---\nname: dup\ndescription: The good one.\n---\nglobal body"}
    ) do |dir|
      catalog = Smith::Skills::Catalog.discover(workspace_dir: dir)

      catalog.skills["dup"].path.should eq(project_skill_path(dir, "dup"))
      catalog.warnings.size.should eq(1)
      catalog.warnings.first.should contain(project_skill_path(dir, "dup"))
      catalog.warnings.first.should_not contain("comes from")
      # The file that lost is still accounted for, so the listing can show it.
      catalog.shadowed["dup"].should eq([global_skill_path(dir, "dup")])
    end
  end
end

# The catalog is built in the CLI's constructor, so a file that raises here
# takes every smith command with it, `smith -v` included.
describe "skills that cannot be read at all" do
  it "warns and skips a SKILL.md it cannot open" do
    with_skill_files do |dir|
      # A directory in its place: unreadable for every user, root included,
      # which a mode-000 file is not.
      FileUtils.mkdir_p(File.join(dir, ".smith", "skills", "folder", "SKILL.md"))

      catalog = Smith::Skills::Catalog.discover(workspace_dir: dir)

      catalog.skills.should be_empty
      catalog.warnings.size.should eq(1)
      catalog.warnings.first.should contain(project_skill_path(dir, "folder"))
      catalog.warnings.first.should contain("could not be read")
    end
  end

  it "warns and skips a SKILL.md that is not valid UTF-8" do
    with_skill_files do |dir|
      FileUtils.mkdir_p(File.join(dir, ".smith", "skills", "latin1"))
      File.write(project_skill_path(dir, "latin1"), Bytes[0x2d, 0x2d, 0x2d, 0x0a, 0xff, 0xfe, 0x0a])

      catalog = Smith::Skills::Catalog.discover(workspace_dir: dir)

      catalog.skills.should be_empty
      catalog.warnings.size.should eq(1)
      catalog.warnings.first.should contain(project_skill_path(dir, "latin1"))
      catalog.warnings.first.should contain("not valid UTF-8")
    end
  end
end
