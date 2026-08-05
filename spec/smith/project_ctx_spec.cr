require "../spec_helper"
require "../../src/smith/project_ctx"

describe Smith::ProjectContext do
  it "discovers local project instructions (SMITH.md)" do
    temp_dir = File.join(Dir.tempdir, "smith_ctx_test_#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(temp_dir)
    smith_md_path = File.join(temp_dir, "SMITH.md")
    File.write(smith_md_path, "Use 2 spaces indentation and Crystal coding style.")

    begin
      ctx = Smith::ProjectContext.discover(start_dir: temp_dir)
      ctx.should_not be_nil
      ctx.not_nil!.should contain("Use 2 spaces indentation and Crystal coding style.")
    ensure
      FileUtils.rm_rf(temp_dir) if Dir.exists?(temp_dir)
    end
  end
end
