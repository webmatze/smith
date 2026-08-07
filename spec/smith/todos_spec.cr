require "../spec_helper"
require "../../src/smith/todos"

private def item(content : String, status : Smith::TodoList::Status)
  Smith::TodoList::Item.new(content, status)
end

describe Smith::TodoList do
  it "starts empty" do
    Smith::TodoList.new.empty?.should be_true
  end

  it "replaces the whole list" do
    list = Smith::TodoList.new
    list.replace([item("Write spec", :pending), item("Run spec", :in_progress)])

    list.items.map(&.content).should eq(["Write spec", "Run spec"])
    list.empty?.should be_false
  end

  it "rejects more than one in_progress item" do
    list = Smith::TodoList.new
    list.replace([item("Keep me", :pending)])

    expect_raises(ArgumentError, /one todo/i) do
      list.replace([item("A", :in_progress), item("B", :in_progress)])
    end

    # The rejected update must not have been applied.
    list.items.map(&.content).should eq(["Keep me"])
  end

  it "accepts an empty list as 'plan finished'" do
    list = Smith::TodoList.new
    list.replace([item("A", :in_progress)])
    list.replace([] of Smith::TodoList::Item)

    list.empty?.should be_true
  end

  it "summarises the counts across all three statuses" do
    list = Smith::TodoList.new
    list.replace([
      item("A", :in_progress),
      item("B", :pending),
      item("C", :pending),
      item("D", :completed),
      item("E", :completed),
      item("F", :completed),
    ])

    list.summary.should eq("1 in progress, 2 pending, 3 completed")
  end

  it "notifies the on_change callback with the new items" do
    list = Smith::TodoList.new
    seen = [] of Array(Smith::TodoList::Item)
    list.on_change = ->(items : Array(Smith::TodoList::Item)) { seen << items; nil }

    list.replace([item("A", :pending)])

    seen.size.should eq(1)
    seen.first.map(&.content).should eq(["A"])
  end

  it "does not notify when the update was rejected" do
    list = Smith::TodoList.new
    calls = 0
    list.on_change = ->(_items : Array(Smith::TodoList::Item)) { calls += 1; nil }

    expect_raises(ArgumentError) do
      list.replace([item("A", :in_progress), item("B", :in_progress)])
    end

    calls.should eq(0)
  end

  it "round-trips items through JSON with snake_case statuses" do
    items = [item("A", :in_progress)]
    json = items.to_json

    json.should contain("in_progress")
    Array(Smith::TodoList::Item).from_json(json).first.status.in_progress?.should be_true
  end
end
