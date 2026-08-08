require "../spec_helper"
require "file_utils"
require "../../src/smith/mentions"

private def with_project(&)
  dir = File.join(Dir.tempdir, "smith_mentions_#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(dir)
  # The tempdir is a symlink on macOS, so the project dir has to be resolved
  # the same way the guard resolves candidate paths — otherwise every relative
  # mention would look like an escape.
  begin
    yield File.realpath(dir)
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def expand(text : String, project_dir : String, **overrides)
  settings = Smith::Mentions::Settings.new(**overrides)
  Smith::Mentions.expand(text, project_dir, settings)
end

describe Smith::Mentions do
  it "embeds a mentioned file and leaves the sentence readable" do
    with_project do |dir|
      File.write(File.join(dir, "notes.md"), "line one\nline two")

      result = expand("look at @notes.md and explain", dir)

      result.text.should contain("look at @notes.md and explain")
      result.text.should contain("--- File: notes.md (2 lines) ---")
      result.text.should contain("line one")
      result.files.map(&.path).should eq(["notes.md"])
    end
  end

  it "leaves email addresses alone" do
    with_project do |dir|
      result = expand("mail foo@bar.com about it", dir)

      result.text.should eq("mail foo@bar.com about it")
      result.files.should be_empty
    end
  end

  it "reads a quoted path with spaces" do
    with_project do |dir|
      File.write(File.join(dir, "my notes.md"), "content")

      result = expand(%(read @"my notes.md" please), dir)

      result.files.map(&.path).should eq(["my notes.md"])
      result.text.should contain("content")
    end
  end

  it "lists a directory instead of inlining what is in it" do
    with_project do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "src", "a.cr"), "puts 1")
      File.write(File.join(dir, "src", "b.cr"), "puts 2")

      result = expand("what is in @src/ ?", dir)

      result.text.should contain("--- Directory: src/ (2 entries) ---")
      result.text.should contain("a.cr")
      result.text.should contain("b.cr")
      result.text.should_not contain("puts 1")
    end
  end

  it "leaves a missing path untouched and reports it rather than failing" do
    with_project do |dir|
      result = expand("look at @nope.cr", dir)

      result.text.should eq("look at @nope.cr")
      result.files.should be_empty
      result.skipped.map(&.path).should eq(["nope.cr"])
      result.skipped.first.reason.should contain("does not exist")
    end
  end

  it "refuses a path that escapes the project" do
    with_project do |dir|
      result = expand("read @../../etc/passwd", dir)

      result.files.should be_empty
      result.skipped.first.reason.should contain("outside the project")
      result.text.should_not contain("root:")
    end
  end

  it "allows the escape when it is explicitly configured" do
    with_project do |dir|
      outside = File.join(Dir.tempdir, "smith_outside_#{Random::Secure.hex(4)}.txt")
      File.write(outside, "external")

      begin
        result = expand("read @#{outside}", dir, allow_outside: true)

        result.files.size.should eq(1)
        result.text.should contain("external")
      ensure
        File.delete(outside) if File.exists?(outside)
      end
    end
  end

  it "truncates a file over the line limit and says so" do
    with_project do |dir|
      File.write(File.join(dir, "big.txt"), (1..10).map { |i| "line #{i}" }.join("\n"))

      result = expand("see @big.txt", dir, max_lines: 3)

      result.text.should contain("line 3")
      result.text.should_not contain("line 4")
      result.text.should contain("truncated")
      result.files.first.truncated?.should be_true
    end
  end

  it "stops embedding once the total budget is spent" do
    with_project do |dir|
      File.write(File.join(dir, "one.txt"), "a" * 200)
      File.write(File.join(dir, "two.txt"), "b" * 200)

      result = expand("@one.txt @two.txt", dir, max_total_bytes: 250)

      result.files.map(&.path).should eq(["one.txt"])
      result.skipped.map(&.path).should eq(["two.txt"])
      result.skipped.first.reason.should contain("budget")
      result.text.should_not contain("b" * 200)
    end
  end

  it "does not embed a binary file" do
    with_project do |dir|
      File.write(File.join(dir, "blob.bin"), "PNG\u0000\u0001binary")

      result = expand("what is @blob.bin", dir)

      result.files.should be_empty
      result.skipped.first.reason.should contain("binary")
    end
  end

  it "embeds several mentions, each once" do
    with_project do |dir|
      File.write(File.join(dir, "a.txt"), "alpha")
      File.write(File.join(dir, "b.txt"), "beta")

      result = expand("compare @a.txt with @b.txt and @a.txt again", dir)

      result.files.map(&.path).should eq(["a.txt", "b.txt"])
      result.text.scan(/--- File: a\.txt/).size.should eq(1)
    end
  end

  it "resolves a mention that a skill body brought in, but goes no deeper" do
    # Skills expand first, so this is the combination the CLI actually builds.
    with_project do |dir|
      File.write(File.join(dir, "inner.txt"), "inner content")
      File.write(File.join(dir, "outer.txt"), "see @inner.txt")

      skill_expanded = "run it\n\n--- Skill Context: demo ---\ncheck @outer.txt"
      result = expand(skill_expanded, dir)

      result.files.map(&.path).should eq(["outer.txt"])
      result.text.should contain("see @inner.txt")
      # One level only: what outer.txt mentions is not pulled in as well.
      result.text.should_not contain("inner content")
    end
  end

  it "ignores a bare @ with nothing after it" do
    with_project do |dir|
      result = expand("what does @ mean", dir)

      result.text.should eq("what does @ mean")
      result.skipped.should be_empty
    end
  end

  it "resolves ~ against the home directory" do
    with_project do |dir|
      File.write(File.join(dir, "home-notes.md"), "from home")

      previous = ENV["HOME"]?
      ENV["HOME"] = dir
      begin
        # Without expansion this would look for a directory literally named "~".
        result = expand("read @~/home-notes.md", dir)

        result.files.map(&.path).should eq(["~/home-notes.md"])
        result.text.should contain("from home")
      ensure
        previous ? (ENV["HOME"] = previous) : ENV.delete("HOME")
      end
    end
  end
end
