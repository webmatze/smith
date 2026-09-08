require "socket"
require "../spec_helper"
require "../../src/smith/cmux_client"
require "../../src/smith/notify"

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
end

describe Smith::CmuxClient do
  describe ".from_table" do
    it "reads the [notify] keys" do
      table = TOML.parse(<<-TOML)
        enabled = true
        socket_path = "/tmp/cmux.sock"
        surface_id = "surface:1"
        workspace_id = "workspace:1"
        timeout = 2.5
        TOML

      config = Smith::CmuxClient.from_table(table)

      config.enabled.should be_true
      config.socket_path.should eq("/tmp/cmux.sock")
      config.surface_id.should eq("surface:1")
      config.workspace_id.should eq("workspace:1")
      config.timeout.should eq(2.5)
    end

    it "says nothing when there is no section at all" do
      config = Smith::CmuxClient.from_table(nil)

      config.enabled.should be_nil
      config.socket_path.should be_nil
      config.deliverable?.should be_false
    end

    it "reads an integer timeout as well as a float one" do
      table = TOML.parse("timeout = 3")

      Smith::CmuxClient.from_table(table).timeout.should eq(3.0)
    end

    it "treats a timeout that could not work as the default" do
      Smith::CmuxClient.from_table(TOML.parse("timeout = 0")).timeout.should eq(1.0)
      Smith::CmuxClient.from_table(TOML.parse("timeout = -1.5")).timeout.should eq(1.0)
    end

    it "turns blank strings into unset, so they cannot shadow the environment" do
      table = TOML.parse(<<-TOML)
        enabled = true
        socket_path = "   "
        surface_id = ""
        TOML

      config = Smith::CmuxClient.from_table(table)

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

      config = Smith::CmuxClient.from_table(table)

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

      config = Smith::CmuxClient.from_table(table)

      config.socket_path.should eq("/tmp/cmux.sock")
      config.surface_id.should eq("surface:1")
    end
  end

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
