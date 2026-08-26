require "../spec_helper"
require "file_utils"
require "../../src/smith/paths"

# What a worktree and a submodule leave behind: `.git` as a regular file
# holding a pointer, not a directory.
private def with_checkout(as_file : Bool, &)
  dir = File.join(Dir.tempdir, "smith_git_root_#{Random::Secure.hex(4)}")
  nested = File.join(dir, "src", "deep")
  FileUtils.mkdir_p(nested)

  if as_file
    File.write(File.join(dir, ".git"), "gitdir: /somewhere/else/.git/worktrees/x\n")
  else
    FileUtils.mkdir_p(File.join(dir, ".git"))
  end

  begin
    yield dir, nested
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe "Smith.git_root" do
  it "recognises a normal clone, where .git is a directory" do
    with_checkout(as_file: false) do |dir, nested|
      Smith.git_root?(dir).should be_true
      Smith.git_root(nested).should eq(dir)
    end
  end

  it "recognises a worktree, where .git is a file" do
    with_checkout(as_file: true) do |dir, nested|
      Smith.git_root?(dir).should be_true
      Smith.git_root(nested).should eq(dir)
    end
  end

  it "is nil outside a checkout" do
    dir = File.join(Dir.tempdir, "smith_no_git_#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(dir)

    begin
      Smith.git_root?(dir).should be_false
      # Not asserted against nil: the temp dir may itself sit inside someone\'s
      # checkout. What matters is that this directory is not mistaken for a root.
      Smith.git_root(dir).should_not eq(dir)
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
