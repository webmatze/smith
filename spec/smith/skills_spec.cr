require "../spec_helper"
require "../../src/smith/skills"

describe Smith::Skills::Catalog do
  it "discovers skills and expands $skill and /skill invocations" do
    temp_dir = File.join(Dir.tempdir, "smith_skill_test_#{Random::Secure.hex(4)}")
    skill_dir = File.join(temp_dir, ".smith", "skills", "test-runner")
    FileUtils.mkdir_p(skill_dir)

    skill_file = File.join(skill_dir, "SKILL.md")
    File.write(skill_file, "---\nname: test-runner\ndescription: Run crystal spec\n---\n\nRun 'crystal spec' to test everything.")

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
      FileUtils.rm_rf(temp_dir) if Dir.exists?(temp_dir)
    end
  end
end
