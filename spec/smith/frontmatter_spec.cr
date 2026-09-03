require "../spec_helper"
require "../../src/smith/frontmatter"

describe Smith::Frontmatter do
  it "splits fields from body" do
    doc = Smith::Frontmatter.parse(<<-MD)
      ---
      name: reviewer
      description: Reviews a diff.
      ---
      You are a code reviewer.
      MD

    doc["name"].should eq("reviewer")
    doc["description"].should eq("Reviews a diff.")
    doc.body.should eq("You are a code reviewer.")
  end

  it "treats a file without frontmatter as all body" do
    doc = Smith::Frontmatter.parse("Just a prompt.\nSecond line.")

    doc["name"].should be_nil
    doc.body.should eq("Just a prompt.\nSecond line.")
    doc.empty?.should be_true
  end

  it "keeps colons inside a value" do
    Smith::Frontmatter.parse("---\ndescription: Use this: it reviews diffs.\n---\nbody")["description"]
      .should eq("Use this: it reviews diffs.")
  end

  it "strips surrounding quotes" do
    doc = Smith::Frontmatter.parse(%(---\nname: "reviewer"\nmodel: 'claude-sonnet-5'\n---\nbody))

    doc["name"].should eq("reviewer")
    doc["model"].should eq("claude-sonnet-5")
  end

  it "reads a comma-separated list" do
    doc = Smith::Frontmatter.parse("---\ntools: read_file, grep,glob ,\n---\nbody")

    doc.list("tools").should eq(["read_file", "grep", "glob"])
  end

  it "returns nil for a list that was never given, and empty for an empty one" do
    doc = Smith::Frontmatter.parse("---\ntools:\n---\nbody")

    doc.list("nothing").should be_nil
    doc.list("tools").should eq([] of String)
  end

  it "ignores comments and blank lines" do
    doc = Smith::Frontmatter.parse("---\n# a comment\n\nname: x\n---\nbody")

    doc["name"].should eq("x")
    doc.fields.size.should eq(1)
  end

  it "leaves a body containing --- alone" do
    doc = Smith::Frontmatter.parse("---\nname: x\n---\nintro\n\n---\n\nmore")

    doc.body.should eq("intro\n\n---\n\nmore")
  end

  it "flags a header that was opened but never closed" do
    doc = Smith::Frontmatter.parse("---\nname: reviewer\ndescription: Reviews a diff.\n\nYou are a code reviewer.\n")

    doc.malformed?.should be_true
    doc["name"].should be_nil
    doc.body.starts_with?("---").should be_true
  end

  it "flags a closed header with no key: value line in it" do
    doc = Smith::Frontmatter.parse("---\njust prose, no colon\n---\nbody")

    doc.malformed?.should be_true
    doc.body.should eq("body")
  end

  it "leaves a readable header, and a file with none at all, unflagged" do
    Smith::Frontmatter.parse("---\nname: x\n---\nbody").malformed?.should be_false
    Smith::Frontmatter.parse("Just a prompt.").malformed?.should be_false
    # A key with an empty value is still a key the author wrote.
    Smith::Frontmatter.parse("---\ntools:\n---\nbody").malformed?.should be_false
  end

  it "flags a byte-order mark or a space in front of the opening ---" do
    # Both defeat HEADER, so the header is read as prose and every field is
    # lost — while the author sees a header they typed correctly.
    Smith::Frontmatter.parse("\uFEFF---\nname: x\n---\nbody").malformed?.should be_true
    Smith::Frontmatter.parse("  ---\nname: x\n---\nbody").malformed?.should be_true
  end

  it "flags a line the header rule cannot read, such as a YAML list" do
    doc = Smith::Frontmatter.parse("---\nname: x\ntools:\n  - read_file\n  - grep\n---\nbody")

    # The fields that did read are still there; the dropped line is the point.
    doc["name"].should eq("x")
    doc.list("tools").should eq([] of String)
    doc.malformed?.should be_true
  end

  it "leaves a markdown file that opens with a thematic break alone" do
    Smith::Frontmatter.parse("---\n\n# Title\n\nprose").malformed?.should be_false
    Smith::Frontmatter.parse("---\n- one\n- two\n").malformed?.should be_false
  end
end
