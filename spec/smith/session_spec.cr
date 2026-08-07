require "../spec_helper"
require "../../src/smith/session"

describe Smith::Session::Store do
  it "creates, saves, lists, and loads sessions atomically" do
    temp_dir = File.join(Dir.tempdir, "smith_session_test_#{Random::Secure.hex(4)}")

    begin
      store = Smith::Session::Store.new(base_dir: temp_dir)

      # Create session
      session = store.create(model: "qwen/qwen3.8-max", provider: "openrouter", cwd: "/tmp")
      session.id.should start_with("session-")

      # Add message & save
      session.messages << Smith::LLM::Message.user("Hello from spec test!")
      session.messages << Smith::LLM::Message.assistant("Hello back!")
      store.save(session)

      # List sessions
      entries = store.list
      entries.size.should eq(1)
      entries.first.id.should eq(session.id)
      entries.first.first_prompt.should eq("Hello from spec test!")
      entries.first.message_count.should eq(2)

      # Load session
      loaded = store.load(session.id)
      loaded.id.should eq(session.id)
      loaded.model.should eq("qwen/qwen3.8-max")
      loaded.messages.size.should eq(2)
      loaded.messages.first.content.first.text.should eq("Hello from spec test!")
      loaded.messages.last.content.first.text.should eq("Hello back!")
    ensure
      FileUtils.rm_rf(temp_dir) if Dir.exists?(temp_dir)
    end
  end
end

describe "todo persistence" do
  it "round-trips the todo list so 'smith resume' restores the plan" do
    temp_dir = File.join(Dir.tempdir, "smith_session_todos_#{Random::Secure.hex(4)}")

    begin
      store = Smith::Session::Store.new(base_dir: temp_dir)
      session = store.create(model: "m", provider: "openrouter", cwd: "/tmp")

      session.todos = [
        Smith::TodoList::Item.new("Implement the tool", Smith::TodoList::Status::InProgress),
        Smith::TodoList::Item.new("Update the README", Smith::TodoList::Status::Pending),
      ]
      store.save(session)

      loaded = store.load(session.id)
      loaded.todos.map(&.content).should eq(["Implement the tool", "Update the README"])
      loaded.todos.first.status.in_progress?.should be_true
    ensure
      FileUtils.rm_rf(temp_dir) if Dir.exists?(temp_dir)
    end
  end

  it "defaults to an empty list for sessions written before todos existed" do
    old = %({"id":"session-1","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","cwd":"/tmp","model":"m","provider":"openrouter","messages":[],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}})

    Smith::Session::Data.from_json(old).todos.should be_empty
  end
end
