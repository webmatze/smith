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

describe "the session directory layout" do
  it "writes a session into its own directory" do
    temp_dir = File.join(Dir.tempdir, "smith_layout_#{Random::Secure.hex(4)}")
    begin
      store = Smith::Session::Store.new(base_dir: temp_dir)
      session = store.create(model: "m", provider: "openrouter")

      File.exists?(File.join(store.sessions_dir, session.id, "session.json")).should be_true
      store.session_dir(session.id).should eq(File.join(store.sessions_dir, session.id))
    ensure
      FileUtils.rm_rf(temp_dir) if Dir.exists?(temp_dir)
    end
  end

  it "still reads and lists a session written in the old flat layout" do
    temp_dir = File.join(Dir.tempdir, "smith_layout_#{Random::Secure.hex(4)}")
    begin
      store = Smith::Session::Store.new(base_dir: temp_dir)

      # What smith wrote before checkpoints existed.
      legacy = Smith::Session::Data.new(id: "session-legacy", cwd: "/tmp", model: "m", provider: "openrouter")
      legacy.messages << Smith::LLM::Message.user("from the old layout")
      File.write(File.join(store.sessions_dir, "session-legacy.json"), legacy.to_json)

      loaded = store.load("session-legacy")
      loaded.messages.size.should eq(1)

      # And saving it again migrates it forward without losing the old file's content.
      store.save(loaded)
      store.load("session-legacy").messages.size.should eq(1)
    ensure
      FileUtils.rm_rf(temp_dir) if Dir.exists?(temp_dir)
    end
  end

  it "reports a missing session clearly" do
    temp_dir = File.join(Dir.tempdir, "smith_layout_#{Random::Secure.hex(4)}")
    begin
      store = Smith::Session::Store.new(base_dir: temp_dir)
      expect_raises(ArgumentError, /not found/) { store.load("session-nope") }
    ensure
      FileUtils.rm_rf(temp_dir) if Dir.exists?(temp_dir)
    end
  end
end

describe Smith::Session::Transcript do
  it "cuts the transcript at the given index" do
    messages = [
      Smith::LLM::Message.user("one"),
      Smith::LLM::Message.assistant("two"),
      Smith::LLM::Message.user("three"),
    ]

    Smith::Session::Transcript.truncate(messages, 1).map(&.role).should eq([Smith::LLM::Role::User])
  end

  it "never leaves a tool_use without its results" do
    # Providers reject a request where one half of the pair is missing — the
    # same invariant Context.compact upholds.
    messages = [
      Smith::LLM::Message.user("do it"),
      Smith::LLM::Message.assistant_with_blocks([
        Smith::LLM::ContentBlock.text("working"),
        Smith::LLM::ContentBlock.tool_use("call_1", "write_file", JSON.parse("{}")),
      ]),
      Smith::LLM::Message.tool_results([Smith::LLM::ContentBlock.tool_result("call_1", "ok")]),
    ]

    # Index 2 would keep the tool_use and drop its results.
    kept = Smith::Session::Transcript.truncate(messages, 2)

    kept.size.should eq(1)
    kept.first.role.should eq(Smith::LLM::Role::User)
  end

  it "keeps a complete pair" do
    messages = [
      Smith::LLM::Message.user("do it"),
      Smith::LLM::Message.assistant_with_blocks([
        Smith::LLM::ContentBlock.tool_use("call_1", "write_file", JSON.parse("{}")),
      ]),
      Smith::LLM::Message.tool_results([Smith::LLM::ContentBlock.tool_result("call_1", "ok")]),
    ]

    Smith::Session::Transcript.truncate(messages, 3).size.should eq(3)
  end

  it "leaves an index past the end alone" do
    messages = [Smith::LLM::Message.user("one")]

    Smith::Session::Transcript.truncate(messages, 99).size.should eq(1)
  end
end
