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

private def with_store(&)
  temp_dir = File.join(Dir.tempdir, "smith_session_names_#{Random::Secure.hex(4)}")
  begin
    yield Smith::Session::Store.new(base_dir: temp_dir)
  ensure
    FileUtils.rm_rf(temp_dir) if Dir.exists?(temp_dir)
  end
end

private def session_with(store, prompt : String)
  session = store.create(model: "m", provider: "anthropic")
  session.messages << Smith::LLM::Message.user(prompt)
  store.save(session)
  session
end

describe "session names" do
  it "derives a readable name from the first prompt" do
    with_store do |store|
      # Five words, punctuation dropped, kebab-case — short enough to type.
      session = session_with(store, "Refactor the agent loop, then add tests for it")

      store.load(session.id).name.should eq("refactor-the-agent-loop-then")
    end
  end

  it "leaves a session with no prompt unnamed rather than inventing one" do
    with_store do |store|
      session = store.create(model: "m", provider: "anthropic")
      store.save(session)

      store.load(session.id).name.should be_nil
    end
  end

  it "does not rewrite a name once it exists" do
    with_store do |store|
      session = session_with(store, "first prompt here")
      store.rename(session.id, "my-refactor")

      reloaded = store.load(session.id)
      reloaded.messages << Smith::LLM::Message.user("a later prompt")
      store.save(reloaded)

      store.load(session.id).name.should eq("my-refactor")
    end
  end

  it "keeps derived names distinct so resuming by name stays unambiguous" do
    with_store do |store|
      first = session_with(store, "fix the tests")
      second = session_with(store, "fix the tests")

      store.load(first.id).name.should eq("fix-the-tests")
      store.load(second.id).name.should eq("fix-the-tests-2")
    end
  end

  it "resolves a session by name or by id" do
    with_store do |store|
      session = session_with(store, "some work")
      store.rename(session.id, "my-refactor")

      store.resolve("my-refactor").id.should eq(session.id)
      store.resolve(session.id).id.should eq(session.id)
    end
  end

  it "refuses to rename onto a name another session already uses" do
    with_store do |store|
      first = session_with(store, "one")
      second = session_with(store, "two")
      store.rename(first.id, "shared")

      expect_raises(ArgumentError, /already/) { store.rename(second.id, "shared") }
    end
  end

  it "lists the candidates instead of picking one when a name is ambiguous" do
    with_store do |store|
      # Only reachable if the files were edited by hand, but silently picking
      # one of them would be worse than saying so.
      first = session_with(store, "one")
      second = session_with(store, "two")
      store.rename(first.id, "shared")
      forced = store.load(second.id)
      forced.name = "shared"
      store.save(forced, derive_name: false, check_name: false)

      message = expect_raises(ArgumentError, /ambiguous/) { store.resolve("shared") }.message.not_nil!
      message.should contain(first.id)
      message.should contain(second.id)
    end
  end

  it "reports an unknown reference as not found" do
    with_store do |store|
      expect_raises(ArgumentError, /not found/) { store.resolve("no-such-session") }
    end
  end

  it "keeps loading a session file written before names existed" do
    with_store do |store|
      session = store.create(model: "m", provider: "anthropic")
      legacy = %({"id":"#{session.id}","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z",) +
               %("cwd":"/tmp","model":"m","provider":"anthropic","messages":[],) +
               %("usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}})
      File.write(File.join(store.session_dir(session.id), "session.json"), legacy)

      loaded = store.load(session.id)
      loaded.name.should be_nil
      loaded.parent_id.should be_nil
    end
  end
end

describe "forking a session" do
  it "copies the transcript into an independent session" do
    with_store do |store|
      original = session_with(store, "explore option A")

      forked = store.fork(original.id)

      forked.id.should_not eq(original.id)
      forked.parent_id.should eq(original.id)
      forked.messages.size.should eq(1)

      forked.messages << Smith::LLM::Message.user("option B instead")
      store.save(forked)

      store.load(original.id).messages.size.should eq(1)
      store.list.map(&.id).should contain(forked.id)
    end
  end

  it "names the fork after the session it came from" do
    with_store do |store|
      original = session_with(store, "explore option A")
      store.rename(original.id, "option-a")

      store.fork(original.id).name.should eq("option-a-fork")
    end
  end
end

describe "resolving a checkpoint against the transcript" do
  it "cuts just after the message the checkpoint named" do
    messages = [
      Smith::LLM::Message.user("first"),
      Smith::LLM::Message.assistant("second"),
      Smith::LLM::Message.user("third"),
    ]

    Smith::Session::Transcript.index_after(messages, messages[1].id).should eq(2)
  end

  it "answers nil when compaction replaced that message" do
    # A guess would cut the transcript somewhere the user never picked.
    messages = [Smith::LLM::Message.user("Summary of the earlier conversation: ...")]

    Smith::Session::Transcript.index_after(messages, "m-gone").should be_nil
  end

  it "still names the same message after a prefix became a summary" do
    kept = Smith::LLM::Message.user("the turn I care about")
    before = [Smith::LLM::Message.user("old"), Smith::LLM::Message.assistant("older"), kept]
    after = [Smith::LLM::Message.user("Summary of the earlier conversation: ..."), kept]

    Smith::Session::Transcript.index_after(before, kept.id).should eq(3)
    Smith::Session::Transcript.index_after(after, kept.id).should eq(2)
  end
end

private def usage(prompt = 0, completion = 0)
  Smith::LLM::Usage.new(prompt, completion, prompt + completion)
end

describe "the cost column in the session index" do
  it "carries usage and model into the index so a cost can be stated" do
    with_store do |store|
      session = store.create(model: "claude-sonnet-5", provider: "anthropic")
      session.messages << Smith::LLM::Message.user("price me")
      session.usage = session.usage + usage(prompt: 1_000_000, completion: 1_000_000)
      store.save(session)

      entry = store.list.find { |e| e.id == session.id }.not_nil!
      entry.cost.should_not be_nil
      entry.cost.not_nil!.should be_close(18.0, 0.001)
    end
  end

  it "says nothing rather than guessing at an unknown model" do
    with_store do |store|
      session = store.create(model: "some-unreleased-model", provider: "openai")
      session.messages << Smith::LLM::Message.user("price me")
      session.usage = session.usage + usage(prompt: 1_000_000)
      store.save(session)

      entry = store.list.find { |e| e.id == session.id }.not_nil!
      entry.cost.should be_nil
    end
  end

  it "honours pricing overrides from config" do
    with_store do |store|
      session = store.create(model: "claude-sonnet-5", provider: "anthropic")
      session.messages << Smith::LLM::Message.user("price me")
      session.usage = session.usage + usage(prompt: 1_000_000, completion: 1_000_000)
      store.save(session)

      overrides = {"anthropic/claude-sonnet-5" => Smith::Pricing::Rates.new(input: 1.0, output: 2.0)}
      entry = store.list.find { |e| e.id == session.id }.not_nil!

      entry.cost(overrides).not_nil!.should be_close(3.0, 0.001)
    end
  end

  it "prices a session with no usage yet as zero, not unknown" do
    with_store do |store|
      session = store.create(model: "claude-sonnet-5", provider: "anthropic")
      session.messages << Smith::LLM::Message.user("not run yet")
      store.save(session)

      entry = store.list.find { |e| e.id == session.id }.not_nil!
      entry.cost.should eq(0.0)
    end
  end

  it "keeps loading index entries written before costs existed" do
    legacy = %([{"id":"session-old","created_at":"2026-01-01T00:00:00Z",) +
             %("updated_at":"2026-01-01T00:00:00Z","first_prompt":"from before",) +
             %("message_count":3}])

    entries = Array(Smith::Session::IndexEntry).from_json(legacy)
    entries.size.should eq(1)
    entries.first.provider.should be_nil
    entries.first.usage.should be_nil
    entries.first.cost.should be_nil
  end
end

# Rewrites the index entry for `id` with a backdated updated_at, so prune has
# something old to look at — save() always stamps Time.local.
private def backdate(store, id : String, to : Time)
  entries = store.list.map do |e|
    if e.id == id
      Smith::Session::IndexEntry.new(
        id: e.id, created_at: to, updated_at: to,
        first_prompt: e.first_prompt, message_count: e.message_count,
        name: e.name, parent_id: e.parent_id,
        provider: e.provider, model: e.model, usage: e.usage
      )
    else
      e
    end
  end
  File.write(store.index_path, entries.to_json)
end

describe "deleting a session" do
  it "removes the file, the directory and the index entry" do
    with_store do |store|
      session = session_with(store, "delete me")
      dir = store.session_dir(session.id)

      store.delete(session.id)

      store.list.should be_empty
      Dir.exists?(dir).should be_false
      File.exists?(File.join(dir, "session.json")).should be_false
    end
  end

  it "accepts a name as well as an id" do
    with_store do |store|
      session = session_with(store, "delete me by name")
      store.rename(session.id, "short-lived")

      store.delete("short-lived")

      store.list.should be_empty
      Dir.exists?(store.session_dir(session.id)).should be_false
    end
  end

  it "leaves the other sessions alone" do
    with_store do |store|
      doomed = session_with(store, "delete me")
      keeper = session_with(store, "keep me")

      store.delete(doomed.id)

      store.list.map(&.id).should eq([keeper.id])
      Dir.exists?(store.session_dir(keeper.id)).should be_true
    end
  end

  it "also removes a session still lying in the old flat layout" do
    with_store do |store|
      legacy = Smith::Session::Data.new(id: "session-legacy", cwd: "/tmp", model: "m", provider: "openrouter")
      legacy.messages << Smith::LLM::Message.user("from the old layout")
      File.write(File.join(store.sessions_dir, "session-legacy.json"), legacy.to_json)

      store.delete("session-legacy")

      File.exists?(File.join(store.sessions_dir, "session-legacy.json")).should be_false
      store.list.should be_empty
    end
  end

  it "resolve_entry names a session without touching it" do
    with_store do |store|
      session = session_with(store, "delete me later")

      entry = store.resolve_entry(session.id)

      entry.not_nil!.id.should eq(session.id)
      store.list.size.should eq(1)
      Dir.exists?(store.session_dir(session.id)).should be_true
    end
  end

  it "reports an unknown reference rather than deleting nothing" do
    with_store do |store|
      expect_raises(ArgumentError, /not found/) { store.delete("no-such-session") }
    end
  end

  it "finds nothing to delete on an empty store" do
    with_store do |store|
      expect_raises(ArgumentError, /not found/) { store.delete("anything") }
    end
  end
end

describe "pruning sessions" do
  it "drops everything older than the cutoff" do
    with_store do |store|
      old = session_with(store, "old work")
      fresh = session_with(store, "fresh work")
      backdate(store, old.id, Time.local - 40.days)

      doomed = store.prune(older_than: 30.days)

      doomed.map(&.id).should eq([old.id])
      store.list.map(&.id).should eq([fresh.id])
      Dir.exists?(store.session_dir(old.id)).should be_false
    end
  end

  it "never deletes the newest session, even past the cutoff" do
    with_store do |store|
      older = session_with(store, "older work")
      newest = session_with(store, "newest work")
      backdate(store, older.id, Time.local - 90.days)
      backdate(store, newest.id, Time.local - 80.days)

      doomed = store.prune(older_than: 30.days)

      doomed.map(&.id).should eq([older.id])
      store.list.map(&.id).should eq([newest.id])
    end
  end

  it "keeps a single stale session rather than emptying the store" do
    with_store do |store|
      session = session_with(store, "the only one")
      backdate(store, session.id, Time.local - 90.days)

      store.prune(older_than: 30.days).should be_empty
      store.list.size.should eq(1)
    end
  end

  it "honours keep_last regardless of age" do
    with_store do |store|
      first = session_with(store, "one")
      second = session_with(store, "two")
      third = session_with(store, "three")
      backdate(store, first.id, Time.local - 60.days)
      backdate(store, second.id, Time.local - 50.days)
      backdate(store, third.id, Time.local - 40.days)

      doomed = store.prune(older_than: 30.days, keep_last: 2)

      doomed.map(&.id).should eq([first.id])
      store.list.map(&.id).should eq([third.id, second.id])
    end
  end

  it "leaves everything alone when nothing is old enough" do
    with_store do |store|
      session_with(store, "recent work")

      store.prune(older_than: 30.days).should be_empty
      store.list.size.should eq(1)
    end
  end

  it "changes nothing on a dry run but names what would go" do
    with_store do |store|
      old = session_with(store, "old work")
      session_with(store, "fresh work")
      backdate(store, old.id, Time.local - 40.days)

      doomed = store.prune(older_than: 30.days, dry_run: true)

      doomed.map(&.id).should eq([old.id])
      store.list.size.should eq(2)
      Dir.exists?(store.session_dir(old.id)).should be_true
    end
  end

  it "finds nothing to prune on an empty store" do
    with_store do |store|
      store.prune(older_than: 30.days).should be_empty
      store.list.should be_empty
    end
  end

  it "protects the session that is being resumed" do
    with_store do |store|
      resuming = session_with(store, "resuming this")
      other = session_with(store, "other work")
      backdate(store, resuming.id, Time.local - 40.days)
      backdate(store, other.id, Time.local - 5.days)

      doomed = store.prune(older_than: 30.days, protect: resuming.id)

      doomed.map(&.id).should be_empty
      store.list.size.should eq(2)
    end
  end
end

describe "a damaged session index" do
  it "costs the damaged entry and no other session" do
    with_store do |store|
      good = session_with(store, "still here")
      broken = JSON.parse(%({"id": "session-broken", "updated_at": "not-a-timestamp"}))
      File.write(store.index_path, ([broken] + JSON.parse(File.read(store.index_path)).as_a).to_json)

      entries, damage = store.read_index

      entries.map(&.id).should eq([good.id])
      damage.size.should eq(1)
      damage.first.should contain("index entry 1")
      # The listing, resume-by-name, delete and stats all read this.
      store.list.map(&.id).should eq([good.id])
      store.resolve_id(good.name.not_nil!).should eq(good.id)
    end
  end

  it "reports an index that is not a list of sessions at all" do
    with_store do |store|
      session_with(store, "still here")
      File.write(store.index_path, "{ not even an array")

      entries, damage = store.read_index

      entries.should be_empty
      damage.first.should contain("not a readable list of sessions")
    end
  end
end

describe "a session reference" do
  it "is a name or an id, never a path" do
    with_store do |store|
      session_with(store, "a real session")

      # `File.join` defuses an absolute path but carries `..` through, so this
      # used to resolve — and read, or with `sessions delete` remove — a
      # directory outside the sessions tree entirely.
      ["../elsewhere", "../../etc", "sessions/x", "/etc/passwd", "..", ".", ""].each do |reference|
        expect_raises(ArgumentError, /is not a session reference/) do
          store.resolve_id(reference)
        end
      end
    end
  end

  it "cannot be renamed into one either" do
    with_store do |store|
      session = session_with(store, "a real session")

      expect_raises(ArgumentError, /is not a session reference/) do
        store.rename(session.id, "../evil")
      end
    end
  end

  it "still resolves a slash-shaped name an earlier release allowed" do
    with_store do |store|
      # `rename` accepted this before the guard existed, and the name is in
      # both index.json and session.json of every session named that way.
      # Refusing to resolve it would strand a session that is still listed.
      session = session_with(store, "a branch-shaped name")
      session.name = "feat/export"
      store.save(session, derive_name: false, check_name: false)

      store.resolve_id("feat/export").should eq(session.id)
      store.resolve("feat/export").id.should eq(session.id)
      store.list.first.name.should eq("feat/export")
    end
  end

  it "deletes such a session by its name without touching anything else" do
    with_store do |store|
      session = session_with(store, "a branch-shaped name")
      session.name = "feat/export"
      store.save(session, derive_name: false, check_name: false)

      store.delete("feat/export").try(&.id).should eq(session.id)
      Dir.exists?(store.session_dir(session.id)).should be_false
      # Never `sessions/feat`, which is what a path-shaped name would name.
      Dir.exists?(File.join(store.sessions_dir, "feat")).should be_false
    end
  end

  it "refuses to remove anything a path could reach, even from a hand-edited index" do
    with_store do |store|
      session_with(store, "a real session")
      outside = File.join(store.base_dir, "victim")
      FileUtils.mkdir_p(outside)
      File.write(File.join(outside, "keepme.txt"), "secret")

      expect_raises(ArgumentError, /is not a session reference/) { store.delete("../victim") }

      # An id is only ever a generated one — unless someone writes their own.
      File.write(store.index_path, %([{"id": "../victim", "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z", "first_prompt": "x", "message_count": 0}]))
      expect_raises(ArgumentError, /is not a session reference/) { store.delete("../victim") }

      File.exists?(File.join(outside, "keepme.txt")).should be_true
    end
  end

  it "does not resolve an id the index carries that is really a path" do
    with_store do |store|
      # Resolution's promise: what comes back can be a directory name under
      # sessions/, whatever the index says. An entry edited to `../victim`
      # would otherwise be read — by export, resume and context alike.
      File.write(store.index_path, %([{"id": "../victim", "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z", "first_prompt": "x", "message_count": 0, "name": "innocent"}]))

      expect_raises(ArgumentError, /is not a session reference/) { store.resolve_id("../victim") }
      # And not by the back door either: the name matches, the id is the path.
      expect_raises(ArgumentError, /is a path rather than a session id/) { store.resolve_id("innocent") }
    end
  end

  it "refuses to build a session path out of anything but a session id" do
    with_store do |store|
      # The seam. `resolve_id` guarantees this for what the user types, but
      # `latest`, `load` and the checkpoint commands reach a session by an id
      # straight out of the index or off the command line — so the promise
      # has to hold here, or it holds nowhere.
      ["../victim", "../../etc", "sessions/x", "/etc/passwd", "..", ".", ""].each do |hostile|
        expect_raises(ArgumentError, /is not a session reference/) { store.session_dir(hostile) }
        expect_raises(ArgumentError, /is not a session reference/) { store.load(hostile) }
      end

      # And a real session still goes through all of it.
      session = session_with(store, "a real session")
      store.session_dir(session.id).should eq(File.join(store.sessions_dir, session.id))
      store.load(session.id).id.should eq(session.id)
    end
  end

  it "skips a poisoned newest entry rather than making it the default session" do
    with_store do |store|
      # `smith resume` and `smith context` with no argument go through
      # `latest`, which never touched resolution at all.
      warnings = IO::Memory.new
      store = Smith::Session::Store.new(base_dir: store.base_dir, warn_io: warnings)
      real = session_with(store, "the real session")

      entries = JSON.parse(File.read(store.index_path)).as_a
      rogue = JSON.parse(%({"id": "../victim", "created_at": "2030-01-01T00:00:00Z", "updated_at": "2030-01-01T00:00:00Z", "first_prompt": "x", "message_count": 0}))
      File.write(store.index_path, ([rogue] + entries).to_json)
      store.list.first.id.should eq("../victim") # it really is the newest

      store.latest.try(&.id).should eq(real.id)
      warnings.to_s.should contain("Skipping index entry '../victim'")
    end
  end

  it "prunes past a path-shaped id instead of taking the session down with it" do
    with_store do |store|
      # `prune` runs at the start of every session and never goes through
      # resolution, so raising here would turn one bad line in a file into
      # chat, run and resume refusing to start.
      warnings = IO::Memory.new
      store = Smith::Session::Store.new(base_dir: store.base_dir, warn_io: warnings)
      outside = File.join(store.base_dir, "victim")
      FileUtils.mkdir_p(outside)
      File.write(File.join(outside, "keepme.txt"), "secret")

      keeper = session_with(store, "the newest session")
      entries = JSON.parse(File.read(store.index_path)).as_a
      rogue = JSON.parse(%({"id": "../victim", "created_at": "2020-01-01T00:00:00Z", "updated_at": "2020-01-01T00:00:00Z", "first_prompt": "x", "message_count": 0}))
      File.write(store.index_path, (entries + [rogue]).to_json)

      doomed = store.prune(older_than: 30.days)

      doomed.map(&.id).should eq(["../victim"])
      warnings.to_s.should contain("Not deleting '../victim'")
      # The entry is gone, the directory outside the tree is not.
      store.list.map(&.id).should eq([keeper.id])
      File.exists?(File.join(outside, "keepme.txt")).should be_true
    end
  end

  it "tells a reference that names nothing from one that is refused" do
    with_store do |store|
      # A caller that means to fall back when a session is gone must not also
      # fall back when the reference was refused.
      expect_raises(Smith::Session::NotFound) { store.resolve_id("no-such-session") }

      refused = expect_raises(ArgumentError) { store.resolve_id("../elsewhere") }
      refused.class.should eq(ArgumentError)
    end
  end
end

describe Smith::Session::Retention do
  it "parses days, hours and minutes" do
    Smith::Session::Retention.parse("30d").should eq(30.days)
    Smith::Session::Retention.parse("12h").should eq(12.hours)
    Smith::Session::Retention.parse("15m").should eq(15.minutes)
  end

  it "reads a bare number as days" do
    Smith::Session::Retention.parse("7").should eq(7.days)
  end

  it "rejects garbage with a helpful message" do
    expect_raises(ArgumentError, /Cannot parse/) { Smith::Session::Retention.parse("soon") }
    expect_raises(ArgumentError, /Cannot parse/) { Smith::Session::Retention.parse("") }
  end
end
