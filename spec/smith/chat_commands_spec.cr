require "../spec_helper"
require "../../src/smith/chat_commands"
require "../../src/smith/skills"

describe Smith::ChatCommands do
  it "recognises the built-in mode commands" do
    Smith::ChatCommands.parse("/plan").should eq(Smith::ChatCommand::Plan)
    Smith::ChatCommands.parse("  /NORMAL  ").should eq(Smith::ChatCommand::Normal)
  end

  it "ignores anything else, including bare words and other slash input" do
    Smith::ChatCommands.parse("plan").should be_nil
    Smith::ChatCommands.parse("/deploy").should be_nil
    Smith::ChatCommands.parse("please /plan the work").should be_nil
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
    Smith::ChatCommands.parse("/plan").should eq(Smith::ChatCommand::Plan)
  end
end

describe "the rewind command" do
  it "is recognised as a built-in" do
    Smith::ChatCommands.parse("/rewind").should eq(Smith::ChatCommand::Rewind)
    Smith::ChatCommands.parse("  /REWIND ").should eq(Smith::ChatCommand::Rewind)
  end
end
