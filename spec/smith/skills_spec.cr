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
