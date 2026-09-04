require "../spec_helper"
require "../../src/smith/session_export"

private def with_store(&)
  temp_dir = File.join(Dir.tempdir, "smith_export_test_#{Random::Secure.hex(4)}")
  begin
    yield Smith::Session::Store.new(base_dir: temp_dir)
  ensure
    FileUtils.rm_rf(temp_dir) if Dir.exists?(temp_dir)
  end
end

# A session with one tool call and its result — the shape every real run has.
private def seed_session(store : Smith::Session::Store, provider = "anthropic", model = "claude-opus-5")
  session = store.create(model: model, provider: provider, cwd: "/tmp/project")
  session.messages << Smith::LLM::Message.user("why does this test fail on Linux?")
  session.messages << Smith::LLM::Message.assistant_with_blocks([
    Smith::LLM::ContentBlock.text("Let me look at the spec."),
    Smith::LLM::ContentBlock.tool_use("call-1", "bash", JSON.parse(%({"command": "crystal spec"}))),
  ])
  session.messages << Smith::LLM::Message.tool_results([
    Smith::LLM::ContentBlock.tool_result("call-1", "1019 examples, 0 failures", false),
  ])
  session.usage = Smith::LLM::Usage.new(1_000_000, 100_000, 1_100_000)
  store.save(session)
  session
end

describe Smith::SessionExport do
  it "renders a run as Markdown: name, roles, tool calls, cost" do
    with_store do |store|
      session = seed_session(store)

      markdown = Smith::SessionExport.build(store, session.reference).to_markdown

      markdown.should contain("# #{session.name}")
      markdown.should contain("`#{session.id}`")
      markdown.should contain("anthropic / claude-opus-5")
      markdown.should contain("`/tmp/project`")
      markdown.should contain("### 1 · User")
      markdown.should contain("why does this test fail on Linux?")
      markdown.should contain("### 2 · Assistant")
      markdown.should contain("**Tool call: `bash`**")
      markdown.should contain(%({"command":"crystal spec"}))
      markdown.should contain("### 3 · Tool results")
      markdown.should contain("1019 examples, 0 failures")
      # 1M in at $5 plus 100k out at $25 = $7.50
      markdown.should contain("**Cost:** $7.50")
    end
  end

  it "resolves a session by id as well as by name, like resume does" do
    with_store do |store|
      session = seed_session(store)

      Smith::SessionExport.build(store, session.id).id.should eq(session.id)
      Smith::SessionExport.build(store, session.name.not_nil!).id.should eq(session.id)
    end
  end

  it "says n/a for a model whose rate is unknown rather than guessing" do
    with_store do |store|
      session = seed_session(store, provider: "openrouter", model: "some/unlisted-model")

      document = Smith::SessionExport.build(store, session.reference)

      document.cost.should be_nil
      document.to_markdown.should contain("**Cost:** n/a")
    end
  end

  it "honours [pricing] overrides the way the COST column does" do
    with_store do |store|
      session = seed_session(store, provider: "openrouter", model: "some/unlisted-model")
      overrides = Smith::Pricing::Overrides{
        "openrouter/some/unlisted-model" => Smith::Pricing::Rates.new(input: 1.0, output: 2.0),
      }

      document = Smith::SessionExport.build(store, session.reference, overrides)

      document.cost.should eq(1.2)
    end
  end

  it "prefers the raw transcript over the compaction-shortened session file, and says so" do
    with_store do |store|
      session = seed_session(store)

      log = Smith::TranscriptLog.new(store.session_dir(session.id))
      log.append(session.messages)
      log.append([Smith::LLM::Message.user("a turn compaction later dropped")])

      # What compaction does to the session file: the working history shrinks.
      session.messages = [Smith::LLM::Message.user("(summary of the conversation so far)")]
      store.save(session)

      document = Smith::SessionExport.build(store, session.reference)

      document.source.transcript?.should be_true
      document.messages.size.should eq(4)
      markdown = document.to_markdown
      markdown.should contain("`transcript.jsonl`")
      markdown.should contain("the untouched record")
      markdown.should contain("session file: 1")
      markdown.should contain("a turn compaction later dropped")
    end
  end

  it "falls back to the session file when there is no transcript, and says so" do
    with_store do |store|
      session = seed_session(store)

      document = Smith::SessionExport.build(store, session.reference)

      document.source.session?.should be_true
      document.warnings.should be_empty
      markdown = document.to_markdown
      markdown.should contain("`session.json`")
      markdown.should contain("no raw transcript")
    end
  end

  it "warns when the transcript is the shorter record, since a log write can fail mid-run" do
    with_store do |store|
      session = seed_session(store)

      log = Smith::TranscriptLog.new(store.session_dir(session.id))
      log.append([session.messages.first])

      document = Smith::SessionExport.build(store, session.reference)

      document.source.transcript?.should be_true
      document.warnings.join("\n").should contain("cut short")
    end
  end

  it "skips a truncated transcript line, and says how many it skipped" do
    with_store do |store|
      session = seed_session(store)

      log = Smith::TranscriptLog.new(store.session_dir(session.id))
      log.append([Smith::LLM::Message.user("first")])
      File.open(log.path, "a") { |f| f.puts %({"role":"assistant","content":[{"type":) }
      log.append([Smith::LLM::Message.user("third")])

      document = Smith::SessionExport.build(store, session.reference)

      document.messages.map { |m| m.content.first.text }.should eq(["first", "third"])
      # Silently dropping it would make a record that lost a line look intact.
      document.transcript_skipped.should eq(1)
      document.warnings.join("\n").should contain("1 line(s) of the transcript could not be read")
      document.to_markdown.should contain("1 unreadable line(s) skipped")
    end
  end

  it "exports from the transcript when the session file is gone" do
    with_store do |store|
      session = seed_session(store)

      log = Smith::TranscriptLog.new(store.session_dir(session.id))
      log.append(session.messages)
      File.delete(File.join(store.session_dir(session.id), "session.json"))

      document = Smith::SessionExport.build(store, session.reference)

      document.source.transcript?.should be_true
      document.messages.size.should eq(3)
      document.warnings.join("\n").should contain("No session file")
      # The index still knows the name, the model and what it cost.
      document.name.should eq(session.name)
      document.to_markdown.should contain("**Cost:** $7.50")
    end
  end

  it "exports from the transcript when the session file will not parse" do
    with_store do |store|
      session = seed_session(store)

      log = Smith::TranscriptLog.new(store.session_dir(session.id))
      log.append(session.messages)
      File.write(File.join(store.session_dir(session.id), "session.json"), "{ this is not json")

      document = Smith::SessionExport.build(store, session.id)

      document.source.transcript?.should be_true
      document.warnings.join("\n").should contain("could not be read")
    end
  end

  it "survives a damaged index entry, exporting by name" do
    with_store do |store|
      session = seed_session(store)

      # One unreadable entry beside the good one. Resolving a *name* is the
      # case that needs the index, so it is the one worth testing.
      entries = JSON.parse(File.read(store.index_path)).as_a
      broken = JSON.parse(%({"id": "session-broken", "updated_at": "not-a-timestamp"}))
      File.write(store.index_path, ([broken] + entries).to_json)

      document = Smith::SessionExport.build(store, session.name.not_nil!)

      document.id.should eq(session.id)
      document.messages.size.should eq(3)
      document.name.should eq(session.name)
      document.to_markdown.should contain("**Cost:** $7.50")
      document.warnings.join("\n").should contain("The session index is damaged")
    end
  end

  it "survives an index that is not a list of sessions at all" do
    with_store do |store|
      session = seed_session(store)
      File.write(store.index_path, "{ not even an array")

      # The name is gone with the index, but the id still names the session.
      document = Smith::SessionExport.build(store, session.id)

      document.messages.size.should eq(3)
      document.provider.should eq("anthropic")
      document.warnings.join("\n").should contain("not a readable list of sessions")
    end
  end

  it "refuses a reference that is a path rather than a name or an id" do
    with_store do |store|
      seed_session(store)

      ["../elsewhere", "../../etc", "sessions/x", "/etc/passwd", "..", "."].each do |reference|
        expect_raises(ArgumentError, /is not a session reference/) do
          Smith::SessionExport.build(store, reference)
        end
      end
    end
  end

  it "will not read outside the sessions tree, whatever the index claims an id is" do
    with_store do |store|
      outside = File.join(store.base_dir, "victim")
      FileUtils.mkdir_p(outside)
      Smith::TranscriptLog.new(outside).append([Smith::LLM::Message.user("I am outside the sessions dir")])
      File.write(store.index_path, %([{"id": "../victim", "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z", "first_prompt": "x", "message_count": 1}]))

      expect_raises(ArgumentError, /is not a session reference/) do
        Smith::SessionExport.build(store, "../victim")
      end
    end
  end

  it "exports a session whose name an earlier release let contain a slash" do
    with_store do |store|
      session = seed_session(store)
      session.name = "feat/export"
      store.save(session, derive_name: false, check_name: false)

      document = Smith::SessionExport.build(store, "feat/export")

      document.id.should eq(session.id)
      document.messages.size.should eq(3)
    end
  end

  it "does not swallow an ambiguous name just because a directory of that name has a transcript" do
    with_store do |store|
      first = seed_session(store)
      second = seed_session(store)
      # Only reachable by editing files by hand, which is why it is refused.
      File.write(store.index_path, [
        first.to_index_entry, Smith::Session::IndexEntry.new(
          id: second.id, created_at: second.created_at, updated_at: second.updated_at,
          first_prompt: "x", message_count: 3, name: first.name),
      ].to_json)
      Smith::TranscriptLog.new(store.session_dir(first.name.not_nil!)).append([Smith::LLM::Message.user("decoy")])

      expect_raises(ArgumentError, /ambiguous/) do
        Smith::SessionExport.build(store, first.name.not_nil!)
      end
    end
  end

  it "exports a directory that lost both its session file and its index entry" do
    with_store do |store|
      session = seed_session(store)

      log = Smith::TranscriptLog.new(store.session_dir(session.id))
      log.append(session.messages)
      File.delete(File.join(store.session_dir(session.id), "session.json"))
      File.write(store.index_path, %([{"id": "session-broken"}]))

      document = Smith::SessionExport.build(store, session.id)

      document.source.transcript?.should be_true
      document.messages.size.should eq(3)
      # Nothing but the id is known any more, and the export says as much.
      document.to_markdown.should contain("unknown / unknown")
      document.to_markdown.should contain("**Cost:** n/a")

      parsed = JSON.parse(document.to_json_document)
      parsed["usage"].raw.should be_nil
      parsed["cost_usd"].raw.should be_nil
    end
  end

  it "refuses a reference that names nothing, with a message and no stack trace" do
    with_store do |store|
      expect_raises(ArgumentError, /not found/) do
        Smith::SessionExport.build(store, "no-such-session")
      end
    end
  end

  it "says so when a session directory holds neither a session file nor a transcript" do
    with_store do |store|
      session = seed_session(store)
      File.delete(File.join(store.session_dir(session.id), "session.json"))

      expect_raises(ArgumentError, /nothing to export/) do
        Smith::SessionExport.build(store, session.id)
      end
    end
  end

  it "renders an image as a placeholder, never as inlined base64" do
    with_store do |store|
      session = store.create(model: "claude-opus-5", provider: "anthropic")
      base64 = "iVBORw0KGgo#{"A" * 4_000}"
      session.messages << Smith::LLM::Message.new(Smith::LLM::Role::User, [
        Smith::LLM::ContentBlock.text("what is on this screenshot?"),
        Smith::LLM::ContentBlock.image("image/png", base64, "screenshot.png"),
      ])
      store.save(session)

      # Loading is what puts the bytes back into the block, from media/.
      loaded = store.load(session.id)
      loaded.messages.last.content.last.data.should_not be_nil

      markdown = Smith::SessionExport.build(store, session.id).to_markdown

      markdown.should contain("[Image: screenshot.png (image/png)")
      markdown.should_not contain(base64)
      markdown.size.should be < 2_000
    end
  end

  it "abbreviates a huge tool result instead of pasting a whole build log" do
    with_store do |store|
      session = store.create(model: "claude-opus-5", provider: "anthropic")
      session.messages << Smith::LLM::Message.tool_results([
        Smith::LLM::ContentBlock.tool_result("call-1", "x" * 50_000, false),
      ])
      store.save(session)

      markdown = Smith::SessionExport.build(store, session.id).to_markdown

      markdown.should contain("abbreviated; 50000 characters in total")
      markdown.size.should be < 5_000
    end
  end

  it "fences tool output that itself contains backticks so the Markdown stays intact" do
    with_store do |store|
      session = store.create(model: "claude-opus-5", provider: "anthropic")
      session.messages << Smith::LLM::Message.tool_results([
        Smith::LLM::ContentBlock.tool_result("call-1", "```crystal\nputs 1\n```", false),
      ])
      store.save(session)

      markdown = Smith::SessionExport.build(store, session.id).to_markdown

      markdown.should contain("````\n```crystal")
    end
  end

  it "keeps a code fence a message never closed from swallowing the rest of the document" do
    with_store do |store|
      session = store.create(model: "claude-opus-5", provider: "anthropic")
      # An assistant turn cut off at max_tokens, mid code block.
      session.messages << Smith::LLM::Message.assistant("Here is the patch:\n\n```crystal\ndef fix\n  puts 1")
      session.messages << Smith::LLM::Message.user("thanks")
      store.save(session)

      markdown = Smith::SessionExport.build(store, session.id).to_markdown

      markdown.lines.count { |line| line.matches?(/\A {0,3}`{3,}/) }.should eq(2)
      # The turn after it is still a heading, not code.
      markdown.should contain("### 2 · User")
    end
  end

  it "closes an unclosed tilde fence too, which is what a model reaches for" do
    with_store do |store|
      session = store.create(model: "claude-opus-5", provider: "anthropic")
      # `~~~` is chosen precisely when the content already holds backticks.
      session.messages << Smith::LLM::Message.assistant("Like so:\n\n~~~markdown\n```\nstill inside\n```")
      session.messages << Smith::LLM::Message.user("thanks")
      store.save(session)

      markdown = Smith::SessionExport.build(store, session.id).to_markdown

      markdown.should contain("\n~~~\n")
      markdown.should contain("### 2 · User")
    end
  end

  it "leaves a balanced tilde fence alone" do
    with_store do |store|
      session = store.create(model: "claude-opus-5", provider: "anthropic")
      session.messages << Smith::LLM::Message.assistant("Balanced:\n\n~~~\n```\ncode\n```\n~~~")
      store.save(session)

      markdown = Smith::SessionExport.build(store, session.id).to_markdown

      markdown.lines.count { |line| line.matches?(/\A {0,3}~{3,}\s*\z/) }.should eq(2)
    end
  end

  it "leaves a closed fence alone, even one showing a shorter fence inside it" do
    with_store do |store|
      session = store.create(model: "claude-opus-5", provider: "anthropic")
      # Three fence lines, all balanced: the inner ``` is content of the ````
      # block, the way a README documenting Markdown writes it.
      session.messages << Smith::LLM::Message.assistant("Nest them:\n\n````markdown\n```\ncode\n```\n````")
      session.messages << Smith::LLM::Message.user("clear")
      store.save(session)

      markdown = Smith::SessionExport.build(store, session.id).to_markdown

      markdown.lines.count { |line| line.matches?(/\A {0,3}`{3,}/) }.should eq(4)
      markdown.should contain("### 2 · User")
    end
  end

  it "makes an export of non-UTF-8 tool output readable text, on both paths" do
    with_store do |store|
      # Latin-1 bytes, a NUL, a BEL and a raw ANSI escape — what a `bash`
      # result picks up from a program that does not speak UTF-8.
      dirty = String.new(Bytes[0x48, 0x69, 0x20, 0xE4, 0xF6, 0xFC, 0x0A, 0x00, 0x07, 0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x21])
      dirty.valid_encoding?.should be_false

      session = store.create(model: "claude-opus-5", provider: "anthropic")
      session.messages << Smith::LLM::Message.tool_results([
        Smith::LLM::ContentBlock.tool_result("call-1", dirty, false),
      ])
      store.save(session)

      document = Smith::SessionExport.build(store, session.id)

      markdown = document.to_markdown
      markdown.valid_encoding?.should be_true
      markdown.should_not contain('\u0000')
      markdown.should_not contain('\u0007')
      markdown.should_not contain('\u001b')
      # The text either side of the damage survives.
      markdown.should contain("Hi ")
      markdown.should contain("[31m!")

      json = document.to_json_document
      json.valid_encoding?.should be_true
      JSON.parse(json)["messages"].as_a.size.should eq(1)
    end
  end

  it "prints timestamps with their offset, so Markdown and JSON name the same instant" do
    with_store do |store|
      session = seed_session(store)

      document = Smith::SessionExport.build(store, session.id)

      # `Z` on a machine running in UTC, an offset anywhere else.
      document.to_markdown.should match(/\*\*Created:\*\* \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} (?:[+-]\d{2}:\d{2}|Z)/)
    end
  end

  it "marks a synthetic user message as smith's own, not something the user typed" do
    with_store do |store|
      session = store.create(model: "claude-opus-5", provider: "anthropic")
      session.messages << Smith::LLM::Message.user("Continue.", synthetic: true)
      store.save(session)

      Smith::SessionExport.build(store, session.id).to_markdown.should contain("User _(continuation by smith)_")
    end
  end

  it "renders thinking and an error result without losing either" do
    with_store do |store|
      session = store.create(model: "claude-opus-5", provider: "anthropic")
      session.messages << Smith::LLM::Message.assistant_with_blocks([
        Smith::LLM::ContentBlock.thinking("The spec is platform dependent.", "sig"),
      ])
      session.messages << Smith::LLM::Message.tool_results([
        Smith::LLM::ContentBlock.tool_result("call-1", "No such file", true),
      ])
      store.save(session)

      markdown = Smith::SessionExport.build(store, session.id).to_markdown

      markdown.should contain("**Thinking**")
      markdown.should contain("> The spec is platform dependent.")
      markdown.should contain("**Tool result** (`call-1`) — error")
    end
  end

  it "exports the structured log as one JSON document, carrying no base64" do
    with_store do |store|
      session = seed_session(store)
      session.todos = [Smith::TodoList::Item.new("Fix the spec", Smith::TodoList::Status::Completed)]
      session.messages << Smith::LLM::Message.new(Smith::LLM::Role::User, [
        Smith::LLM::ContentBlock.image("image/png", "iVBORw0KGgo#{"A" * 2_000}", "shot.png"),
      ])
      store.save(session)

      raw = Smith::SessionExport.build(store, session.id).to_json_document
      parsed = JSON.parse(raw)

      parsed["id"].as_s.should eq(session.id)
      parsed["name"].as_s.should eq(session.name)
      parsed["source"].as_s.should eq("session.json")
      parsed["cost_usd"].as_f.should be_close(7.5, 0.001)
      parsed["message_count"].as_i.should eq(4)
      parsed["todos"][0]["content"].as_s.should eq("Fix the spec")
      parsed["messages"].as_a.size.should eq(4)
      raw.should_not contain("AAAAAAAA")
      # Round-trips into the type it came from, so a tool can read it back.
      Array(Smith::LLM::Message).from_json(parsed["messages"].to_json).size.should eq(4)
    end
  end

  it "reports an unknown cost as null in JSON, not as zero" do
    with_store do |store|
      session = seed_session(store, provider: "openrouter", model: "some/unlisted-model")

      parsed = JSON.parse(Smith::SessionExport.build(store, session.id).to_json_document)

      parsed["cost_usd"].raw.should be_nil
    end
  end
end
