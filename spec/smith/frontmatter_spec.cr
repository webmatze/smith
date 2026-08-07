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
end
