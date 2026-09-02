require "../../spec_helper"
require "../../../src/smith/ui/completions"

include Smith::UI

private def sample_list : Array(Smith::UI::Completion)
  [
    Completion.new(name: "/plan", description: "plan mode"),
    Completion.new(name: "/clear", description: "clear context"),
    Completion.new(name: "/resume", description: "switch session", takes_args: true),
    Completion.new(name: "/test", description: "a skill", takes_args: true, builtin: false),
    Completion.new(name: "/plan-review", description: "a skill", takes_args: true, builtin: false),
  ]
end

describe Smith::UI::CommandPalette do
  it "treats a bare slash as a query and lists everything" do
    palette = CommandPalette.new(sample_list)
    palette.update("/")

    palette.open?.should be_true
    palette.matches.size.should eq(5)
  end

  it "filters by prefix, case-insensitively" do
    palette = CommandPalette.new(sample_list)
    palette.update("/cle")

    palette.matches.map(&.name).should eq(["/clear"])
  end

  it "lists built-ins before skills" do
    palette = CommandPalette.new(sample_list)
    palette.update("/p")

    palette.matches.map(&.name).should eq(["/plan", "/plan-review"])
  end

  it "stays closed when nothing matches" do
    palette = CommandPalette.new(sample_list)
    palette.update("/zzz")

    palette.open?.should be_false
    palette.current.should be_nil
  end

  it "clamps the selection at both ends" do
    palette = CommandPalette.new(sample_list)
    palette.update("/")

    palette.move_up
    palette.selected.should eq(0)

    (sample_list.size + 3).times { palette.move_down }
    palette.selected.should eq(sample_list.size - 1)
  end

  it "resets the selection when the query changes" do
    palette = CommandPalette.new(sample_list)
    palette.update("/")
    palette.move_down
    palette.selected.should eq(1)

    palette.update("/")
    palette.selected.should eq(0)
  end

  it "keeps the selection inside the visible window" do
    list = (1..12).map { |i| Completion.new(name: "/cmd#{i.to_s.rjust(2, '0')}", description: "d") }
    palette = CommandPalette.new(list)
    palette.update("/")

    [5, 10, 11, 11].each do |steps|
      steps.times { palette.move_down }
      palette.visible.map(&.name).should contain(palette.current.not_nil!.name)
    end

    [3, 3, 3, 5].each do |steps|
      steps.times { palette.move_up }
      palette.visible.map(&.name).should contain(palette.current.not_nil!.name)
    end
  end

  it "limits the popup to a screenful of rows" do
    list = (1..12).map { |i| Completion.new(name: "/cmd#{i}", description: "d") }
    palette = CommandPalette.new(list)
    palette.update("/")

    palette.visible.size.should eq(CommandPalette::VISIBLE_ROWS)
  end
end

describe ".query_for" do
  it "accepts a bare slash word" do
    CommandPalette.query_for("/").should eq("/")
    CommandPalette.query_for("/cl").should eq("/cl")
  end

  it "rejects ordinary text and command-plus-argument" do
    CommandPalette.query_for("").should be_nil
    CommandPalette.query_for("hello").should be_nil
    CommandPalette.query_for("/resume x").should be_nil
    CommandPalette.query_for("hello /plan").should be_nil
  end
end
