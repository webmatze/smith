require "../spec_helper"
require "../../src/smith/hooks"

private def definition(
  command : String,
  event : Smith::Hooks::Event = Smith::Hooks::Event::PreToolUse,
  matcher : String? = nil,
  timeout : Int32 = 60,
  once : Bool = false,
)
  Smith::Hooks::Definition.new(
    event: event,
    matcher: matcher.try { |m| Regex.new(m) },
    command: command,
    timeout: timeout,
    once: once
  )
end

private def runner(*definitions : Smith::Hooks::Definition, warn_io : IO = IO::Memory.new)
  Smith::Hooks::Runner.new(definitions.to_a, session_id: "spec-session", warn_io: warn_io)
end

private def payload(tool_name : String = "write_file", tool_args = {"path" => "src/foo.cr"})
  JSON.parse({"tool_name" => tool_name, "tool_args" => tool_args}.to_json)
end

describe Smith::Hooks::Event do
  it "maps to and from the config/protocol spelling" do
    Smith::Hooks::Event::PreToolUse.to_key.should eq("pre_tool_use")
    Smith::Hooks::Event.from_key("pre_tool_use").should eq(Smith::Hooks::Event::PreToolUse)
    Smith::Hooks::Event.from_key("user_prompt_submit").should eq(Smith::Hooks::Event::UserPromptSubmit)
    Smith::Hooks::Event.from_key("nonsense").should be_nil
  end
end

describe Smith::Hooks::Runner do
  it "does nothing when no hook is defined" do
    outcome = Smith::Hooks::Runner.new.run(Smith::Hooks::Event::PreToolUse, payload)

    outcome.blocked?.should be_false
    outcome.additional_context.should be_nil
  end

  it "runs a hook whose matcher matches the tool name" do
    marker = File.tempname("smith_hook", ".txt")
    begin
      runner(definition("echo fired > #{marker}", matcher: "write_file|edit_file"))
        .run(Smith::Hooks::Event::PreToolUse, payload("write_file"))

      File.exists?(marker).should be_true
    ensure
      File.delete(marker) if File.exists?(marker)
    end
  end

  it "skips a hook whose matcher does not match" do
    marker = File.tempname("smith_hook", ".txt")
    begin
      runner(definition("echo fired > #{marker}", matcher: "write_file"))
        .run(Smith::Hooks::Event::PreToolUse, payload("read_file"))

      File.exists?(marker).should be_false
    ensure
      File.delete(marker) if File.exists?(marker)
    end
  end

  it "only runs hooks registered for the event being fired" do
    marker = File.tempname("smith_hook", ".txt")
    begin
      runner(definition("echo fired > #{marker}", event: Smith::Hooks::Event::Stop))
        .run(Smith::Hooks::Event::PreToolUse, payload)

      File.exists?(marker).should be_false
    ensure
      File.delete(marker) if File.exists?(marker)
    end
  end

  it "feeds the hook a JSON payload on stdin, plus the session envelope" do
    marker = File.tempname("smith_hook", ".json")
    begin
      runner(definition("cat > #{marker}")).run(Smith::Hooks::Event::PreToolUse, payload("write_file"))

      received = JSON.parse(File.read(marker))
      received["hook_event_name"].as_s.should eq("pre_tool_use")
      received["session_id"].as_s.should eq("spec-session")
      received["cwd"].as_s.should eq(Dir.current)
      received["tool_name"].as_s.should eq("write_file")
      received["tool_args"]["path"].as_s.should eq("src/foo.cr")
    ensure
      File.delete(marker) if File.exists?(marker)
    end
  end

  it "exports the documented environment variables" do
    outcome = runner(definition(
      %(echo "$SMITH_HOOK_EVENT|$SMITH_SESSION_ID|$SMITH_PROJECT_DIR"),
      event: Smith::Hooks::Event::PostToolUse
    )).run(Smith::Hooks::Event::PostToolUse, payload)

    outcome.additional_context.not_nil!.strip.should eq("post_tool_use|spec-session|#{Dir.current}")
  end

  it "blocks on exit code 2 and passes stderr back as the reason" do
    outcome = runner(definition("echo 'secrets are not allowed here' >&2; exit 2"))
      .run(Smith::Hooks::Event::PreToolUse, payload)

    outcome.blocked?.should be_true
    outcome.reason.not_nil!.should contain("secrets are not allowed here")
  end

  it "blocks on a JSON deny decision" do
    outcome = runner(definition(%(echo '{"decision":"deny","reason":"company policy"}')))
      .run(Smith::Hooks::Event::PreToolUse, payload)

    outcome.blocked?.should be_true
    outcome.reason.should eq("company policy")
  end

  it "replaces the tool arguments via updated_input" do
    outcome = runner(definition(%(echo '{"decision":"allow","updated_input":{"path":"src/bar.cr"}}')))
      .run(Smith::Hooks::Event::PreToolUse, payload)

    outcome.blocked?.should be_false
    outcome.updated_input.not_nil!["path"].as_s.should eq("src/bar.cr")
  end

  it "forces a prompt via an ask decision" do
    outcome = runner(definition(%(echo '{"decision":"ask","reason":"double-check this"}')))
      .run(Smith::Hooks::Event::PreToolUse, payload)

    outcome.ask?.should be_true
    outcome.blocked?.should be_false
  end

  it "collects additional_context from JSON as well as from plain stdout" do
    outcome = runner(
      definition(%(echo '{"additional_context":"from json"}'), event: Smith::Hooks::Event::Stop),
      definition("echo from stdout", event: Smith::Hooks::Event::Stop)
    ).run(Smith::Hooks::Event::Stop, payload)

    context = outcome.additional_context.not_nil!
    context.should contain("from json")
    context.should contain("from stdout")
  end

  it "stops at the first blocking hook but keeps the context gathered so far" do
    marker = File.tempname("smith_hook", ".txt")
    begin
      outcome = runner(
        definition("echo early context"),
        definition("echo nope >&2; exit 2"),
        definition("echo fired > #{marker}")
      ).run(Smith::Hooks::Event::PreToolUse, payload)

      outcome.blocked?.should be_true
      outcome.additional_context.not_nil!.should contain("early context")
      File.exists?(marker).should be_false, "a hook after the blocking one still ran"
    ensure
      File.delete(marker) if File.exists?(marker)
    end
  end
end

describe "a hook that misbehaves" do
  it "does not block on an unexpected exit code, but warns" do
    warnings = IO::Memory.new
    outcome = runner(definition("echo boom >&2; exit 1"), warn_io: warnings)
      .run(Smith::Hooks::Event::PreToolUse, payload)

    outcome.blocked?.should be_false
    warnings.to_s.should contain("exit code 1")
  end

  it "does not block when the command does not exist" do
    warnings = IO::Memory.new
    outcome = runner(definition("definitely-not-a-real-command-xyz"), warn_io: warnings)
      .run(Smith::Hooks::Event::PreToolUse, payload)

    outcome.blocked?.should be_false
  end

  it "does not block when it exceeds its timeout" do
    warnings = IO::Memory.new
    outcome = runner(definition("sleep 5", timeout: 1), warn_io: warnings)
      .run(Smith::Hooks::Event::PreToolUse, payload)

    outcome.blocked?.should be_false
    warnings.to_s.should contain("timed out")
  end

  it "does not block on malformed JSON — it is treated as plain output" do
    outcome = runner(definition(%(echo '{"decision": broken'))).run(Smith::Hooks::Event::PreToolUse, payload)

    outcome.blocked?.should be_false
    outcome.additional_context.not_nil!.should contain("broken")
  end
end

describe "once: true" do
  it "fires exactly once per session" do
    marker = File.tempname("smith_hook", ".txt")
    begin
      hooks = runner(definition("echo x >> #{marker}", once: true))

      3.times { hooks.run(Smith::Hooks::Event::PreToolUse, payload) }

      File.read(marker).lines.size.should eq(1)
    ensure
      File.delete(marker) if File.exists?(marker)
    end
  end

  it "fires every time when once is false" do
    marker = File.tempname("smith_hook", ".txt")
    begin
      hooks = runner(definition("echo x >> #{marker}"))

      3.times { hooks.run(Smith::Hooks::Event::PreToolUse, payload) }

      File.read(marker).lines.size.should eq(3)
    ensure
      File.delete(marker) if File.exists?(marker)
    end
  end
end

describe "hook visibility" do
  it "reports every fired hook, blocking or not" do
    fired = [] of Tuple(Smith::Hooks::Event, String, Bool)
    hooks = runner(definition("true"), definition("exit 2"))
    hooks.on_fire = ->(event : Smith::Hooks::Event, command : String, blocked : Bool) do
      fired << {event, command, blocked}
      nil
    end

    hooks.run(Smith::Hooks::Event::PreToolUse, payload)

    fired.map(&.[1]).should eq(["true", "exit 2"])
    fired.map(&.[2]).should eq([false, true])
  end
end
