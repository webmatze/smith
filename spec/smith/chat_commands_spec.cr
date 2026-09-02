require "../spec_helper"
require "../../src/smith/chat_commands"
require "../../src/smith/skills"

describe Smith::ChatCommands do
  it "recognises the built-in mode commands" do
    Smith::ChatCommands.parse("/plan").try(&.command).should eq(Smith::ChatCommand::Plan)
    Smith::ChatCommands.parse("  /NORMAL  ").try(&.command).should eq(Smith::ChatCommand::Normal)
  end

  it "ignores anything else, including bare words and other slash input" do
    Smith::ChatCommands.parse("plan").should be_nil
    Smith::ChatCommands.parse("/deploy").should be_nil
    Smith::ChatCommands.parse("please /plan the work").should be_nil
  end

  it "leaves a slash invocation with arguments to the skill catalog" do
    # `/deploy staging` is how a skill is called with arguments, so a built-in
    # only claims the bare form.
    Smith::ChatCommands.parse("/plan the release").should be_nil
  end

  it "takes precedence over a skill of the same name" do
    catalog = Smith::Skills::Catalog.new
    catalog.skills["plan"] = Smith::Skills::Skill.new(
      name: "plan",
      description: "A skill that happens to be called plan",
      body: "body",
      path: "/tmp/plan/SKILL.md"
    )

    # The skill catalog would happily claim /plan — which is exactly why the
    # chat loop must resolve built-in commands first.
    catalog.expand_prompt("/plan").should contain("Execute skill 'plan'")
    Smith::ChatCommands.parse("/plan").try(&.command).should eq(Smith::ChatCommand::Plan)
  end
end

describe "the rewind command" do
  it "is recognised as a built-in" do
    Smith::ChatCommands.parse("/rewind").try(&.command).should eq(Smith::ChatCommand::Rewind)
    Smith::ChatCommands.parse("  /REWIND ").try(&.command).should eq(Smith::ChatCommand::Rewind)
  end
end

describe "the session commands" do
  it "reads /context as a built-in" do
    Smith::ChatCommands.parse("/context").try(&.command).should eq(Smith::ChatCommand::Context)
  end

  it "carries the new name along with /rename" do
    invocation = Smith::ChatCommands.parse("/rename my-refactor").not_nil!

    invocation.command.should eq(Smith::ChatCommand::Rename)
    invocation.argument.should eq("my-refactor")
  end

  it "ignores /rename without a name" do
    Smith::ChatCommands.parse("/rename").should be_nil
  end
end

describe "the context and session-switch commands" do
  it "recognises /help, /clear, /sessions and /quit" do
    Smith::ChatCommands.parse("/help").try(&.command).should eq(Smith::ChatCommand::Help)
    Smith::ChatCommands.parse("/clear").try(&.command).should eq(Smith::ChatCommand::Clear)
    Smith::ChatCommands.parse("/sessions").try(&.command).should eq(Smith::ChatCommand::Sessions)
    Smith::ChatCommands.parse("  /QUIT ").try(&.command).should eq(Smith::ChatCommand::Quit)
  end

  it "leaves their bare forms to the skill catalog when they carry arguments" do
    Smith::ChatCommands.parse("/help me").should be_nil
    Smith::ChatCommands.parse("/clear all").should be_nil
    Smith::ChatCommands.parse("/sessions list").should be_nil
    Smith::ChatCommands.parse("/quit now").should be_nil
  end

  it "carries the target along with /resume" do
    invocation = Smith::ChatCommands.parse("/resume my-session").not_nil!

    invocation.command.should eq(Smith::ChatCommand::Resume)
    invocation.argument.should eq("my-session")
  end

  it "ignores /resume without a target" do
    Smith::ChatCommands.parse("/resume").should be_nil
  end
end

describe "the command table" do
  it "exposes every built-in exactly once" do
    verbs = Smith::ChatCommands.definitions.map(&.verb)
    verbs.size.should eq(verbs.uniq.size)

    expected = ["/plan", "/normal", "/clear", "/context", "/rewind", "/sessions", "/resume", "/rename", "/help", "/quit"]
    verbs.sort.should eq(expected.sort)
  end

  it "flags exactly which commands require an argument" do
    args = Smith::ChatCommands.definitions
      .select(&.requires_argument)
      .map(&.verb)

    args.sort.should eq(["/rename", "/resume"])
  end

  it "gives every definition a description the UI can show" do
    Smith::ChatCommands.definitions.each do |d|
      d.description.should_not be_empty
      d.verb.starts_with?('/').should be_true
    end
  end
end
