require "socket"
require "../spec_helper"
require "../../src/smith/cmux_client"
require "../../src/smith/notify"
require "../../src/smith/turn_notifier"
require "../../src/smith/agent"
require "../../src/smith/tools"
require "../../src/smith/cli"
require "../../src/smith/session"

# Records what `Smith::Notify` hands over, so the payload rules can be asserted
# without a cmux daemon — which is the point: nothing here should depend on
# there being one.
# No `CMUX_*` at all: the shape of a shell that is not inside cmux.
private def no_cmux_env : Hash(String, String?)
  {} of String => String?
end

# A config that says everything, so "the environment wins" and "the config is
# left alone" are both observable against it.
private def filled_config : Smith::NotifyConfig
  Smith::NotifyConfig.new(
    enabled: true,
    socket_path: "/config/cmux.sock",
    surface_id: "config-surface",
    workspace_id: "config-workspace"
  )
end

private class RecordingClient < Smith::CmuxClientable
  getter payloads = [] of Hash(String, JSON::Any)
  property result : Bool = true
  property available : Bool = true

  def notify(payload : Hash(String, JSON::Any)) : Bool
    @payloads << payload
    @result
  end

  def available? : Bool
    @available
  end

  def last : Hash(String, JSON::Any)
    @payloads.last
  end
end

# The client a socket implementation will eventually be: one that finds out
# something is wrong only when it tries. A notification is the last thing a
# run does, so whatever this throws must stay inside the notification.
private class ExplodingClient < Smith::CmuxClientable
  def notify(payload : Hash(String, JSON::Any)) : Bool
    raise Socket::ConnectError.new("Connection refused")
  end

  def available? : Bool
    true
  end
end

describe Smith::NotifyConfig do
  it "says nothing at all, and delivers nothing, until something does" do
    config = Smith::NotifyConfig.new

    # `enabled` is tri-state on purpose: nil is "nobody said", which is the
    # answer a terminal is allowed to overrule. false would be somebody
    # turning notifications off, and no environment may overrule that.
    config.enabled.should be_nil
    config.enabled?.should be_false
    config.socket_path.should be_nil
    config.surface_id.should be_nil
    config.workspace_id.should be_nil
    config.socket?.should be_false
    config.deliverable?.should be_false
  end

  it "is deliverable only when enabled and holding a socket path" do
    Smith::NotifyConfig.new(enabled: true).deliverable?.should be_false
    Smith::NotifyConfig.new(socket_path: "/tmp/cmux.sock").deliverable?.should be_false
    Smith::NotifyConfig.new(enabled: true, socket_path: "/tmp/cmux.sock").deliverable?.should be_true
  end

  it "is not deliverable when explicitly turned off, however much else is there" do
    Smith::NotifyConfig.new(enabled: false, socket_path: "/tmp/cmux.sock").deliverable?.should be_false
  end

  it "defaults the timeout to something a socket can live with" do
    Smith::NotifyConfig.new.timeout.should eq(1.0)
  end

  describe ".from_table" do
    it "reads the [notify] keys" do
      table = TOML.parse(<<-TOML)
        enabled = true
        socket_path = "/tmp/cmux.sock"
        surface_id = "surface:1"
        workspace_id = "workspace:1"
        timeout = 2.5
        TOML

      config = Smith::NotifyConfig.from_table(table)

      config.enabled.should be_true
      config.socket_path.should eq("/tmp/cmux.sock")
      config.surface_id.should eq("surface:1")
      config.workspace_id.should eq("workspace:1")
      config.timeout.should eq(2.5)
    end

    it "says nothing when there is no section at all" do
      config = Smith::NotifyConfig.from_table(nil)

      config.enabled.should be_nil
      config.socket_path.should be_nil
      config.deliverable?.should be_false
    end

    it "reads an integer timeout as well as a float one" do
      table = TOML.parse("timeout = 3")

      Smith::NotifyConfig.from_table(table).timeout.should eq(3.0)
    end

    it "treats a timeout that could not work as the default" do
      Smith::NotifyConfig.from_table(TOML.parse("timeout = 0")).timeout.should eq(1.0)
      Smith::NotifyConfig.from_table(TOML.parse("timeout = -1.5")).timeout.should eq(1.0)
    end

    it "turns blank strings into unset, so they cannot shadow the environment" do
      table = TOML.parse(<<-TOML)
        enabled = true
        socket_path = "   "
        surface_id = ""
        TOML

      config = Smith::NotifyConfig.from_table(table)

      config.socket_path.should be_nil
      config.surface_id.should be_nil
      config.socket?.should be_false
    end

    it "ignores a value of the wrong type instead of raising" do
      # A config file is written by a human, and `socket_path = true` is a
      # typo, not a reason for smith to refuse to start.
      table = TOML.parse(<<-TOML)
        enabled = "yes"
        socket_path = 42
        TOML

      config = Smith::NotifyConfig.from_table(table)

      # Not false: an unreadable `enabled` is nobody having said, so the
      # terminal keeps its say rather than a typo switching notifications off.
      config.enabled.should be_nil
      config.socket_path.should be_nil
    end

    it "trims the values it does keep" do
      table = TOML.parse(<<-TOML)
        socket_path = "  /tmp/cmux.sock  "
        surface_id = " surface:1 "
        TOML

      config = Smith::NotifyConfig.from_table(table)

      config.socket_path.should eq("/tmp/cmux.sock")
      config.surface_id.should eq("surface:1")
    end
  end
end

describe Smith::CmuxClient do
  describe ".resolve" do
    it "leaves the config alone when the environment says nothing" do
      resolved = Smith::CmuxClient.resolve(filled_config, no_cmux_env)

      resolved.enabled?.should be_true
      resolved.socket_path.should eq("/config/cmux.sock")
      resolved.surface_id.should eq("config-surface")
      resolved.workspace_id.should eq("config-workspace")
    end

    it "prefers the environment: it describes the terminal that is open now" do
      env = {
        "CMUX_SOCKET_PATH"  => "/env/cmux.sock",
        "CMUX_SURFACE_ID"   => "env-surface",
        "CMUX_WORKSPACE_ID" => "env-workspace",
      } of String => String?

      resolved = Smith::CmuxClient.resolve(filled_config, env)

      resolved.socket_path.should eq("/env/cmux.sock")
      resolved.surface_id.should eq("env-surface")
      resolved.workspace_id.should eq("env-workspace")
    end

    it "switches notifications on inside cmux, without a config file asking" do
      # cmux exports a socket path into every process it spawns; that is how
      # smith knows this session is running inside one. There is no `CMUX=1`
      # flag to read, and the terminal's own environment is checked below.
      silent = Smith::NotifyConfig.new

      Smith::CmuxClient.resolve(silent, {"CMUX_SOCKET_PATH" => "/cmux.sock"}).enabled?.should be_true
    end

    it "leaves notifications off in a shell that is not cmux" do
      # The default has to be "nothing happens" — a plain terminal session
      # must not be changed by this feature, and must not spend a turn
      # looking for a socket that was never there.
      Smith::CmuxClient.resolve(Smith::NotifyConfig.new, no_cmux_env).enabled?.should be_false
    end

    it "honours an explicit enabled = false over the terminal" do
      # Somebody turned them off. Being inside cmux is not a reason to
      # overrule that, which is why `false` is not folded into "unset".
      off = Smith::NotifyConfig.new(enabled: false)

      resolved = Smith::CmuxClient.resolve(off, {"CMUX_SOCKET_PATH" => "/cmux.sock"})

      resolved.enabled?.should be_false
      resolved.deliverable?.should be_false
    end

    it "does not read a socket path from a config file as being inside cmux" do
      # Naming a location is not the same statement as the terminal making
      # itself known: a config file can point at a socket for a session that
      # is not running inside cmux at all. Left to `enabled` to ask for.
      configured = Smith::NotifyConfig.new(socket_path: "/config/cmux.sock")

      Smith::CmuxClient.resolve(configured, no_cmux_env).enabled?.should be_false
    end

    it "reads a falsey socket variable as cmux not being there" do
      # One rule for every variable: a falsey value is an absent value, so it
      # cannot switch notifications on either. This is not a hypothetical —
      # cmux exports `CMUX_SOCKET=` empty alongside a populated
      # `CMUX_SOCKET_PATH` in the same shell.
      %w[0 false no off].each do |value|
        {"CMUX_SOCKET_PATH" => value, "CMUX_SOCKET_PATH" => value.upcase}.each do |key, spelling|
          env = {key => spelling} of String => String?
          Smith::CmuxClient.resolve(Smith::NotifyConfig.new, env).enabled?.should be_false, "#{key}=#{spelling}"
        end
      end
    end

    it "reads an empty socket variable as unset rather than as a location" do
      # `export CMUX_SOCKET=` and no export at all are the same statement.
      # Read as a location it would shadow the real one with nothing.
      env = {"CMUX_SOCKET" => ""} of String => String?

      resolved = Smith::CmuxClient.resolve(filled_config, env)

      resolved.socket_path.should eq("/config/cmux.sock")
      resolved.deliverable?.should be_true
    end

    it "keeps the timeout: it is not something an environment describes" do
      env = {"CMUX_SOCKET_PATH" => "/env/cmux.sock"} of String => String?
      timed = Smith::NotifyConfig.new(timeout: 4.0)

      Smith::CmuxClient.resolve(timed, env).timeout.should eq(4.0)
    end

    describe "socket path priority" do
      it "takes CMUX_SOCKET_PATH over the older spellings" do
        env = {
          "CMUX_SOCKET_PATH" => "/canonical.sock",
          "CMUX_SOCKET"      => "/older.sock",
          "CMUX"             => "/oldest.sock",
        } of String => String?

        Smith::CmuxClient.resolve(filled_config, env).socket_path.should eq("/canonical.sock")
      end

      it "falls back to CMUX_SOCKET, then to CMUX when it looks like a path" do
        Smith::CmuxClient.resolve(filled_config, {"CMUX_SOCKET" => "/older.sock", "CMUX" => "/oldest.sock"} of String => String?).socket_path.should eq("/older.sock")
        Smith::CmuxClient.resolve(filled_config, {"CMUX" => "/tmp/cmux.sock"} of String => String?).socket_path.should eq("/tmp/cmux.sock")
      end

      it "does not read a flag-shaped CMUX as a location" do
        # `CMUX=1` is the shape of a flag, not of a path. Treating `1` as one
        # would connect to a file called `1` in the current directory.
        silent = Smith::NotifyConfig.new
        resolved = Smith::CmuxClient.resolve(silent, {"CMUX" => "1"} of String => String?)

        resolved.socket_path.should be_nil
        # …and a flag is not a socket, so it cannot switch notifications on
        # either: nothing in this environment says "you are inside cmux".
        resolved.enabled?.should be_false
      end

      it "skips a falsey socket variable and keeps looking" do
        env = {
          "CMUX_SOCKET_PATH" => "",
          "CMUX_SOCKET"      => "0",
          "CMUX"             => "/tmp/cmux.sock",
        } of String => String?

        Smith::CmuxClient.resolve(filled_config, env).socket_path.should eq("/tmp/cmux.sock")
      end

      it "falls through to the config when every variable is falsey" do
        env = {
          "CMUX_SOCKET_PATH" => "   ",
          "CMUX_SOCKET"      => "off",
        } of String => String?

        Smith::CmuxClient.resolve(filled_config, env).socket_path.should eq("/config/cmux.sock")
      end

      it "leaves a whitespace surface or workspace id unset" do
        env = {
          "CMUX_SURFACE_ID"   => "  ",
          "CMUX_WORKSPACE_ID" => "",
        } of String => String?

        resolved = Smith::CmuxClient.resolve(filled_config, env)

        resolved.surface_id.should eq("config-surface")
        resolved.workspace_id.should eq("config-workspace")
      end

      it "takes a documented spelling when the exported one is missing" do
        # cmux documents `CMUX_TAB_ID` and `CMUX_PANEL_ID` and exports
        # `CMUX_WORKSPACE_ID`/`CMUX_SURFACE_ID` carrying the same two values.
        # Which pair a build offers is not something smith can ask about, so
        # neither is assumed.
        silent = Smith::NotifyConfig.new
        env = {"CMUX_TAB_ID" => "tab-1", "CMUX_PANEL_ID" => "panel-1"} of String => String?

        resolved = Smith::CmuxClient.resolve(silent, env)

        resolved.workspace_id.should eq("tab-1")
        resolved.surface_id.should eq("panel-1")
      end

      it "prefers the workspace and surface ids it was documented with" do
        env = {
          "CMUX_WORKSPACE_ID" => "workspace-1",
          "CMUX_TAB_ID"       => "tab-1",
          "CMUX_SURFACE_ID"   => "surface-1",
          "CMUX_PANEL_ID"     => "panel-1",
        } of String => String?

        resolved = Smith::CmuxClient.resolve(Smith::NotifyConfig.new, env)

        resolved.workspace_id.should eq("workspace-1")
        resolved.surface_id.should eq("surface-1")
      end
    end
  end

  describe ".build" do
    it "resolves and then builds, in one step" do
      client = Smith::CmuxClient.build(
        Smith::NotifyConfig.new(enabled: true),
        {"CMUX_SOCKET_PATH" => "/tmp/cmux.sock"} of String => String?
      )

      client.should be_a(Smith::CmuxClientable)
    end
  end

  describe ".client" do
    it "is null when notifications are off" do
      Smith::CmuxClient.client(Smith::NotifyConfig.new(socket_path: "/tmp/cmux.sock")).should be_a(Smith::NullCmuxClient)
    end

    it "is null when there is no socket to talk to" do
      Smith::CmuxClient.client(Smith::NotifyConfig.new(enabled: true)).should be_a(Smith::NullCmuxClient)
    end

    it "is null even when everything is in place, until the wire exists" do
      # The seam this PR builds stops here on purpose. When a real client
      # arrives, this is the expectation that changes — and it should change
      # loudly, not by a spec quietly going green.
      config = Smith::NotifyConfig.new(enabled: true, socket_path: "/tmp/cmux.sock")

      Smith::CmuxClient.client(config).should be_a(Smith::NullCmuxClient)
    end
  end
end

describe Smith::NullCmuxClient do
  it "accepts nothing and delivers nothing" do
    client = Smith::NullCmuxClient.new

    client.available?.should be_false
    client.notify(Hash(String, JSON::Any).new).should be_false
  end
end

describe Smith::Notify do
  it "names what kind of message it is sending" do
    client = RecordingClient.new
    Smith::Notify.new(client).notify("Build done")

    client.last["type"].as_s.should eq("notification")
  end

  it "always sends a title, even an empty one" do
    client = RecordingClient.new
    Smith::Notify.new(client).notify("")

    client.last["title"].as_s.should eq("")
  end

  it "sends subtitle and body when they say something" do
    client = RecordingClient.new
    Smith::Notify.new(client).notify("Build done", subtitle: "2 failed", body: "spec/smith/notify_spec.cr")

    client.last["subtitle"].as_s.should eq("2 failed")
    client.last["body"].as_s.should eq("spec/smith/notify_spec.cr")
  end

  it "leaves an absent subtitle or body out of the payload entirely" do
    client = RecordingClient.new
    Smith::Notify.new(client).notify("Build done")

    client.last.has_key?("subtitle").should be_false
    client.last.has_key?("body").should be_false
  end

  it "leaves a blank body out, because an empty one renders as a gap" do
    client = RecordingClient.new
    Smith::Notify.new(client).notify("Build done", subtitle: "   ", body: "")

    client.last.has_key?("subtitle").should be_false
    client.last.has_key?("body").should be_false
  end

  it "trims what it does send" do
    client = RecordingClient.new
    Smith::Notify.new(client).notify("Build done", body: "  all green  ")

    client.last["body"].as_s.should eq("all green")
  end

  it "carries extra fields into the payload" do
    client = RecordingClient.new
    Smith::Notify.new(client).notify("Build done", priority: "high", count: 3, ratio: 0.5, urgent: true, missing: nil)

    client.last["priority"].as_s.should eq("high")
    client.last["count"].as_i.should eq(3)
    client.last["ratio"].as_f.should eq(0.5)
    client.last["urgent"].as_bool.should be_true
    client.last["missing"].raw.should be_nil
  end

  it "carries nested extras, widening the numbers JSON wants" do
    client = RecordingClient.new
    Smith::Notify.new(client).notify("Build done", tags: ["ci", "main"], detail: {"file" => "notify.cr", "line" => 12})

    client.last["tags"].as_a.map(&.as_s).should eq(["ci", "main"])
    client.last["detail"]["file"].as_s.should eq("notify.cr")
    client.last["detail"]["line"].as_i.should eq(12)
  end

  it "lets an extra win over the field notify would have filled in" do
    # The caller knows better than the default here: a `type` of something
    # other than "notification" is a deliberate choice, not a collision.
    client = RecordingClient.new
    Smith::Notify.new(client).notify("Build done", type: "status")

    client.last["type"].as_s.should eq("status")
    client.last["title"].as_s.should eq("Build done")
  end

  it "reports what the client reported" do
    client = RecordingClient.new
    Smith::Notify.new(client).notify("Build done").should be_true

    client.result = false
    Smith::Notify.new(client).notify("Build done").should be_false
  end

  it "reports unavailable, and sends nothing, through a null client" do
    notify = Smith::Notify.new(Smith::NullCmuxClient.new)

    notify.enabled?.should be_false
    notify.notify("Build done").should be_false
  end

  it "reports available when the client has somewhere to deliver to" do
    client = RecordingClient.new
    Smith::Notify.new(client).enabled?.should be_true

    client.available = false
    Smith::Notify.new(client).enabled?.should be_false
  end

  it "swallows a client that throws, because a notification must not end a run" do
    # The socket can vanish between the availability check and the write, and
    # cmux can be killed mid-run. Both are ordinary, and neither is worth the
    # turn that was just completed.
    Smith::Notify.new(ExplodingClient.new).notify("Build done").should be_false
  end

  it "serialises to the JSON a daemon would receive" do
    client = RecordingClient.new
    Smith::Notify.new(client).notify("Build done", subtitle: "2 failed")

    client.last.to_json.should eq(%({"type":"notification","title":"Build done","subtitle":"2 failed"}))
  end
end

# What the first consumer does with a run. Driven through the real agent loop
# wherever a loop exists to drive, because the point of this listener is that
# it reacts to events as they arrive — a hand-written sequence would pass
# whatever order it happened to assert.
private class NotifyingProvider < Smith::LLM::Provider
  getter calls = 0

  def name : String
    "mock"
  end

  def default_model : String
    "mock-model"
  end

  def complete(request : Smith::LLM::Request) : Smith::LLM::Response
    @calls += 1

    if @calls == 1
      # Turn one announces and calls a tool — the announcement is not the
      # answer, and the run is not over.
      blocks = [
        Smith::LLM::ContentBlock.text("Let me look at that."),
        Smith::LLM::ContentBlock.tool_use("call_1", "read_file", JSON.parse(%({"path": "spec/spec_helper.cr"}))),
      ]
    else
      blocks = [
        Smith::LLM::ContentBlock.text("Done. The tests pass."),
      ]
    end

    Smith::LLM::Response.new("resp_#{@calls}", request.model, blocks, usage: Smith::LLM::Usage.new(10, 5, 15))
  end
end

describe Smith::TurnNotifier do
  it "says nothing until the turn is over" do
    client = RecordingClient.new
    notifier = Smith::TurnNotifier.new(Smith::Notify.new(client))

    notifier.handle(Smith::Events::AssistantText.new("thinking out loud"))
    client.payloads.should be_empty

    notifier.handle(Smith::Events::TurnCompleted.new(1))
    client.payloads.size.should eq(1)
  end

  it "names the run and carries where it came from" do
    client = RecordingClient.new
    notifier = Smith::TurnNotifier.new(Smith::Notify.new(client), subtitle: "smith · notify")

    notifier.handle(Smith::Events::AssistantText.new("all green"))
    notifier.handle(Smith::Events::TurnCompleted.new(3))

    payload = client.last
    payload["title"].should eq("Smith")
    payload["subtitle"].should eq("smith · notify")
    payload["body"].should eq("all green")
  end

  it "reports the answer, not the announcement that came before the tools" do
    # What a model says before calling a tool is a promise of work, not a
    # result. Sent as the body it would read, an hour later, as though the run
    # had stopped mid-sentence.
    client = RecordingClient.new
    notifier = Smith::TurnNotifier.new(Smith::Notify.new(client))

    notifier.handle(Smith::Events::AssistantText.new("Let me look at that."))
    notifier.handle(Smith::Events::ToolStart.new("call_1", "read_file", JSON.parse("{}")))
    notifier.handle(Smith::Events::ToolFinished.new("call_1", "read_file", "contents", false))
    notifier.handle(Smith::Events::AssistantText.new("Done."))
    notifier.handle(Smith::Events::TurnCompleted.new(2))

    client.last["body"].should eq("Done.")
  end

  it "sends no body at all for a run that ended among its tools" do
    client = RecordingClient.new
    notifier = Smith::TurnNotifier.new(Smith::Notify.new(client))

    notifier.handle(Smith::Events::AssistantText.new("Let me look at that."))
    notifier.handle(Smith::Events::ToolStart.new("call_1", "read_file", JSON.parse("{}")))
    notifier.handle(Smith::Events::TurnCompleted.new(1))

    client.last.has_key?("body").should be_false
  end

  it "collapses a multi-paragraph answer into one line" do
    client = RecordingClient.new
    notifier = Smith::TurnNotifier.new(Smith::Notify.new(client))

    notifier.handle(Smith::Events::AssistantText.new("First paragraph.\n\nSecond  one,\twith a tab."))
    notifier.handle(Smith::Events::TurnCompleted.new(1))

    client.last["body"].should eq("First paragraph. Second one, with a tab.")
  end

  it "cuts a long answer at a word boundary and says it did" do
    client = RecordingClient.new
    notifier = Smith::TurnNotifier.new(Smith::Notify.new(client))

    long = Array.new(40) { |i| "word#{i}" }.join(" ")
    notifier.handle(Smith::Events::AssistantText.new(long))
    notifier.handle(Smith::Events::TurnCompleted.new(1))

    body = client.last["body"].as_s
    body.size.should be <= Smith::TurnNotifier::MAX_BODY + 1
    body.ends_with?("…").should be_true

    # The cut happened at a space rather than inside a word: what is left is
    # one whole token, and the source had none of any other shape.
    kept = body[0, body.size - 1]
    kept.split(" ").last.should match(/^word\d+$/)
    # …and it dropped something rather than merely trailing off.
    kept.split(" ").size.should be < long.split(" ").size
  end

  it "counts characters rather than bytes, so a body cannot be cut in half" do
    # German text is where this shows: a byte-oriented cut would split a
    # two-byte character and send an invalid string.
    client = RecordingClient.new
    notifier = Smith::TurnNotifier.new(Smith::Notify.new(client))

    long = "Grüße " * 60
    notifier.handle(Smith::Events::AssistantText.new(long))
    notifier.handle(Smith::Events::TurnCompleted.new(1))

    body = client.last["body"].as_s
    body.size.should be <= Smith::TurnNotifier::MAX_BODY + 1
    body.valid_encoding?.should be_true
  end

  it "leaves an answer that fits alone, ellipsis and all" do
    client = RecordingClient.new
    notifier = Smith::TurnNotifier.new(Smith::Notify.new(client))

    notifier.handle(Smith::Events::AssistantText.new("short"))
    notifier.handle(Smith::Events::TurnCompleted.new(1))

    client.last["body"].should eq("short")
  end

  it "notifies once per turn, and again for the next one" do
    client = RecordingClient.new
    notifier = Smith::TurnNotifier.new(Smith::Notify.new(client))

    2.times do |i|
      notifier.handle(Smith::Events::AssistantText.new("turn #{i}"))
      notifier.handle(Smith::Events::TurnCompleted.new(i + 1))
    end

    client.payloads.size.should eq(2)
    client.payloads[0]["body"].should eq("turn 0")
    client.payloads[1]["body"].should eq("turn 1")
  end

  it "drops what a run said before it failed, so the next run starts clean" do
    # A run does not have to end on a completed turn: a provider that fails, a
    # budget that runs out and a window that fills each end one, and none of
    # them is followed by `TurnCompleted`. Whatever was collected belongs to
    # the run that died, and left standing it would be prefixed to the answer
    # of the next one — a session of two turns would notify "second answer"
    # with the first turn's half-answer glued in front of it.
    [
      Smith::Events::TurnError.new("Provider completion failed"),
      Smith::Events::BudgetExceeded.new(spent_usd: 2.0, limit_usd: 1.0),
      Smith::Events::ContextExhausted.new(9000, 8000, 0),
    ].each do |ending|
      client = RecordingClient.new
      notifier = Smith::TurnNotifier.new(Smith::Notify.new(client))

      notifier.handle(Smith::Events::AssistantText.new("the run that died"))
      notifier.handle(ending)
      client.payloads.should be_empty, "#{ending.class} notified"

      notifier.handle(Smith::Events::AssistantText.new("the answer after it"))
      notifier.handle(Smith::Events::TurnCompleted.new(1))

      client.last["body"].should eq("the answer after it"), "#{ending.class} leaked"
    end
  end

  it "ignores everything that is not a turn ending" do
    client = RecordingClient.new
    notifier = Smith::TurnNotifier.new(Smith::Notify.new(client))

    notifier.handle(Smith::Events::ToolStart.new("call_1", "bash", JSON.parse("{}")))
    notifier.handle(Smith::Events::UsageUpdated.new(Smith::LLM::Usage.new(1, 1, 2)))
    notifier.handle(Smith::Events::TurnError.new("provider said no"))
    notifier.handle(Smith::Events::BudgetExceeded.new(spent_usd: 1.5, limit_usd: 1.0))

    client.payloads.should be_empty
  end

  it "says nothing through a null client, and survives a client that throws" do
    # Not inside cmux is the ordinary case: a plain terminal run must not be
    # changed by this feature, and must not pay for it either.
    null_notifier = Smith::TurnNotifier.new(Smith::Notify.new(Smith::NullCmuxClient.new))
    null_notifier.handle(Smith::Events::TurnCompleted.new(1))

    # A notification is the last thing a run does; it must not be the reason
    # one ends. This call is the assertion: a client that throws out of
    # `handle` fails the example right here.
    exploding = Smith::TurnNotifier.new(Smith::Notify.new(ExplodingClient.new))
    exploding.handle(Smith::Events::TurnCompleted.new(1))
  end

  describe "through the real agent loop" do
    it "is told by the events a run actually emits" do
      provider = NotifyingProvider.new
      registry = Smith::Tools::Registry.default
      agent = Smith::Agent.new(provider: provider, registry: registry, model: "mock-model")

      client = RecordingClient.new
      notifier = Smith::TurnNotifier.new(Smith::Notify.new(client), subtitle: "spec-project")

      # The same two lines `CLI#build_agent` runs, which is the wiring under
      # test: a listener alongside the renderer rather than inside it.
      agent.on_event { |event| notifier.handle(event) }
      agent.send("Read spec_helper and tell me when the tests pass")

      # One notification for the whole run — the intermediate turn that called
      # a tool announced itself and was not over.
      client.payloads.size.should eq(1)
      payload = client.last
      payload["type"].should eq("notification")
      payload["title"].should eq("Smith")
      payload["subtitle"].should eq("spec-project")
      payload["body"].should eq("Done. The tests pass.")
    end
  end
end

# The wiring itself: what `CLI#build_agent` attaches, and what a resolved
# notification says about where the run is. Reaching into the private helpers
# rather than restating them is the same reason clear_persist_spec.cr does —
# a copy written out in the spec would pass whatever the CLI happened to do.
class Smith::CLI
  def notify_for_spec : Smith::Notify
    notify
  end

  def notify_subtitle_for_spec(session : Smith::Session::Data?) : String?
    notify_subtitle(session)
  end

  def config_for_spec : Smith::Config
    @config
  end
end

describe "the notifications a CLI run is wired to send" do
  it "resolves to nothing to deliver to in a shell that is not cmux" do
    # The default has to be "a plain terminal run is unchanged": nothing is
    # delivered, and nothing is even looked for. Resolved against an
    # environment passed in rather than the ambient one — these specs run
    # inside a real cmux terminal more often than not, and a test that reads
    # `ENV` would then assert the opposite of what it claims.
    temp_dir = File.join(Dir.tempdir, "smith_wire_#{Random::Secure.hex(4)}")
    previous = ENV["SMITH_HOME"]?
    ENV["SMITH_HOME"] = temp_dir

    begin
      cli = Smith::CLI.new([] of String)

      resolved = Smith::CmuxClient.resolve(cli.config_for_spec.notify, {} of String => String?)
      resolved.enabled?.should be_false
      resolved.deliverable?.should be_false
    ensure
      previous ? (ENV["SMITH_HOME"] = previous) : ENV.delete("SMITH_HOME")
      FileUtils.rm_rf(temp_dir)
    end
  end

  it "delivers nothing yet, inside cmux or not" do
    # The seam this stops at, asserted rather than assumed: `Notify#enabled?`
    # reports whether there is a client that can deliver, and until the socket
    # is spoken to there is only the null one. So the wiring is complete and
    # still sends nothing — which is why `build_agent` can attach it
    # unconditionally instead of branching on "am I inside cmux?".
    temp_dir = File.join(Dir.tempdir, "smith_wire_#{Random::Secure.hex(4)}")
    previous = ENV["SMITH_HOME"]?
    ENV["SMITH_HOME"] = temp_dir

    begin
      cli = Smith::CLI.new([] of String)
      notify = cli.notify_for_spec

      notify.enabled?.should be_false
      # …and a run finishing still costs nothing and still fails nothing.
      notifier = Smith::TurnNotifier.new(notify)
      notifier.handle(Smith::Events::TurnCompleted.new(1))
    ensure
      previous ? (ENV["SMITH_HOME"] = previous) : ENV.delete("SMITH_HOME")
      FileUtils.rm_rf(temp_dir)
    end
  end

  it "names the project a session was started in" do
    # Read off the session rather than `Dir.current`: a resumed session runs
    # wherever it was created, and that is the name worth reading from another
    # tab. Built rather than created, because `Store#create` writes a session
    # file — and a spec has no business leaving one in the developer's
    # `~/.smith`.
    session = Smith::Session::Data.new(id: "spec-session", cwd: "/work/smith", model: "mock-model", provider: "mock")

    Smith::CLI.new([] of String).notify_subtitle_for_spec(session).should eq("smith")
  end

  it "prefers a session name when it has one" do
    session = Smith::Session::Data.new(
      id: "spec-session",
      cwd: "/work/smith",
      model: "mock-model",
      provider: "mock",
      name: "notify-work"
    )

    Smith::CLI.new([] of String).notify_subtitle_for_spec(session).should eq("smith · notify-work")
  end

  it "still names something when there is no session yet" do
    # A headless run has one, but the helper must not depend on it: it is
    # called from the same place the agent is built, and a nil session is a
    # state that reaches it.
    Smith::CLI.new([] of String).notify_subtitle_for_spec(nil).should eq(File.basename(Dir.current))
  end
end
