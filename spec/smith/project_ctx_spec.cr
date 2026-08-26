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

  it "stops at a worktree root, so a neighbour's instructions stay out" do
    outer = File.join(Dir.tempdir, "smith_ctx_worktree_#{Random::Secure.hex(4)}")
    project = File.join(outer, "worktree")
    FileUtils.mkdir_p(project)

    # Worktrees are typically collected under one shared parent, which is
    # exactly where somebody else's AGENTS.md is likely to sit.
    File.write(File.join(outer, "AGENTS.md"), "Instructions from outside the project.")
    File.write(File.join(project, "SMITH.md"), "Instructions that belong to it.")
    File.write(File.join(project, ".git"), "gitdir: #{outer}/.git/worktrees/worktree\n")

    begin
      ctx = Smith::ProjectContext.discover(start_dir: project).to_s
      ctx.should contain("Instructions that belong to it.")
      ctx.should_not contain("Instructions from outside the project.")
    ensure
      FileUtils.rm_rf(outer) if Dir.exists?(outer)
    end
  end
end
