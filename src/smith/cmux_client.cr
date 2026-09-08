require "toml"
require "./cmux_clientable"
require "./null_cmux_client"
require "./notify_config"

module Smith
  # Turns the two places a cmux notification setup can be described — the
  # `[notify]` section of config.toml and the `CMUX_*` environment the cmux
  # terminal exports into every process it spawns — into one `NotifyConfig`,
  # and that into something `Smith::Notify` can talk to.
  #
  # This is the only place that knows those names. `Smith::Notify` sees a
  # resolved config and a `CmuxClientable`; neither knows there is an
  # environment, and neither reaches for one.
  module CmuxClient
    # In priority order. `CMUX_SOCKET_PATH` is the one cmux documents and the
    # one its environment actually carries.
    #
    # The other two are kept because they cost nothing to check and because a
    # spelling smith refused to read is a notification that silently does not
    # arrive: `CMUX_SOCKET` is exported alongside the documented name — empty,
    # in the environment this was written against, which is exactly why a
    # resolution has to read the first value that says something rather than
    # the first variable that is set — and `CMUX` is the spelling #120 named
    # and the one a wrapper script is most likely to set itself.
    SOCKET_PATH_KEYS = {"CMUX_SOCKET_PATH", "CMUX_SOCKET", "CMUX"}

    # Two pairs of names for the same two values. cmux's own CLI and docs speak
    # of tabs and panels, and the environment this was written against exports
    # `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID` carrying the same two ids its
    # `CMUX_TAB_ID` and `CMUX_PANEL_ID` do — both halves verified, not assumed.
    #
    # Reading both costs nothing, and which pair a build exports is not
    # something smith can ask about. The workspace and surface names come
    # first: they are the ones observed, and the tab and panel names are the
    # ones a build might stop exporting.
    WORKSPACE_ID_KEYS = {"CMUX_WORKSPACE_ID", "CMUX_TAB_ID"}
    SURFACE_ID_KEYS   = {"CMUX_SURFACE_ID", "CMUX_PANEL_ID"}

    # Values an environment variable can hold that mean "not set" rather than
    # "set to this": a shell that exports one of these is saying the same thing
    # as one that never exported it, so the next tier down gets its say.
    #
    # Not a hypothetical. cmux exports `CMUX_SOCKET=` empty alongside a
    # populated `CMUX_SOCKET_PATH` in the same environment, so a resolution
    # that read the first set *variable* rather than the first set *value*
    # would find no socket at all — and would then conclude the session is not
    # running inside cmux, because the socket is what says so.
    FALSEY = {"", "0", "false", "no", "off"}

    DEFAULT_TIMEOUT = 1.0

    # The config tier, before the environment has had a say. Blank strings
    # become nil, so `socket_path = ""` in a config file is the same as the key
    # not being there — otherwise the empty value would shadow the environment
    # with nothing.
    #
    # `enabled` keeps its third state for the same reason: absent is "nobody
    # said", and that is the answer the environment gets to overrule.
    def self.from_table(table : Hash(String, TOML::Any)? = nil) : NotifyConfig
      timeout = float_setting(table, "timeout")

      NotifyConfig.new(
        enabled: setting(table, "enabled").try(&.as_bool?),
        socket_path: normalize(setting(table, "socket_path").try(&.as_s?)),
        surface_id: normalize(setting(table, "surface_id").try(&.as_s?)),
        workspace_id: normalize(setting(table, "workspace_id").try(&.as_s?)),
        timeout: timeout.nil? || timeout <= 0 ? DEFAULT_TIMEOUT : timeout
      )
    end

    # Config plus environment, environment winning. Inside cmux the variables
    # describe the terminal that is running right now — this surface, this
    # workspace, this socket — so they are the more accurate answer than
    # anything a config file could have been written with.
    #
    # `env` is a parameter rather than `ENV` so the resolution is testable
    # without touching the process environment.
    def self.resolve(config : NotifyConfig, env : Hash(String, String?) = env_snapshot) : NotifyConfig
      # A socket cmux itself put into the environment, as opposed to one a
      # config file named. Kept apart because the two mean different things:
      # the first says "this terminal is inside cmux, right now", the second
      # only says "here is a location".
      live_socket = socket_from_env(env)

      NotifyConfig.new(
        enabled: enabled(config, live_socket),
        socket_path: live_socket || config.socket_path,
        surface_id: first_of(env, SURFACE_ID_KEYS) || config.surface_id,
        workspace_id: first_of(env, WORKSPACE_ID_KEYS) || config.workspace_id,
        timeout: config.timeout
      )
    end

    # Resolve, then build. The one call a caller that is not itself resolving
    # anything needs.
    def self.build(config : NotifyConfig, env : Hash(String, String?) = env_snapshot) : CmuxClientable
      client(resolve(config, env))
    end

    # The client for an already-resolved config. Kept separate from `resolve`
    # because resolving is pure: a diagnostic can compute the effective config
    # without anything being connected.
    #
    # Null whenever delivering is impossible, so the caller never has to ask
    # first.
    def self.client(config : NotifyConfig) : CmuxClientable
      return NullCmuxClient.new unless config.deliverable?

      # TODO: open the unix socket at `config.socket_path` and speak to it
      # (#120). Until then every config resolves to null — the plumbing is
      # here, the wire is not, and nothing silently claims a notification was
      # delivered.
      NullCmuxClient.new
    end

    # Whether notifications go out. Three answers, because there are three
    # questions and only two of them belong to the config file:
    #
    # An explicit `enabled = false` is honoured no matter what the terminal
    # says — that is somebody turning them off, and being inside cmux is not a
    # reason to overrule them. An explicit `true` is honoured as readily.
    #
    # Absent is nobody having said, and that is where the terminal gets its
    # say: cmux announcing a socket *is* the announcement that this session is
    # running inside it, which is the situation a completion notification
    # exists for. So the default is on inside cmux and off everywhere else,
    # and a run started in a plain terminal is unchanged by this feature.
    #
    # Deliberately not decided by whether a socket path resolved *from config*:
    # pointing at a location is not the same statement as "you are inside me",
    # and treating it as one would switch notifications on for a config file
    # that only ever meant to say where the socket is.
    private def self.enabled(config : NotifyConfig, live_socket : String?) : Bool
      explicit = config.enabled
      return explicit unless explicit.nil?

      !live_socket.nil?
    end

    private def self.socket_from_env(env : Hash(String, String?)) : String?
      SOCKET_PATH_KEYS.each do |key|
        value = truthy(env, key)
        next if value.nil?
        # A bare `CMUX` holds a flag in the wild — `CMUX=1` — and reading that
        # as a location would connect to a file called `1` in the current
        # directory. Only something shaped like a path is taken as one.
        next if key == "CMUX" && !value.includes?("/")
        return value
      end

      nil
    end

    # The first of `keys` that holds a value saying something, so a documented
    # spelling can stand in for an exported one without either being assumed.
    private def self.first_of(env : Hash(String, String?), keys : Enumerable(String)) : String?
      keys.each do |key|
        value = presence(env, key)
        return value unless value.nil?
      end

      nil
    end

    private def self.setting(table : Hash(String, TOML::Any)?, key : String) : TOML::Any?
      table.try(&.[key]?)
    end

    # TOML writes `timeout = 2` as an integer and `timeout = 0.5` as a float,
    # and both are the same statement — `as_f?` reads either.
    private def self.float_setting(table : Hash(String, TOML::Any)?, key : String) : Float64?
      setting(table, key).try(&.as_f?)
    end

    # A set variable that says something. Whitespace-only and the usual
    # spellings of "off" come back as nil, which is what lets the tier below
    # speak.
    private def self.truthy(env : Hash(String, String?), key : String) : String?
      value = normalize(env[key]?)
      return nil if value.nil?
      FALSEY.includes?(value.downcase) ? nil : value
    end

    private def self.presence(env : Hash(String, String?), key : String) : String?
      normalize(env[key]?)
    end

    private def self.normalize(value : String?) : String?
      return nil if value.nil?
      stripped = value.strip
      stripped.empty? ? nil : stripped
    end

    # A copy of the process environment, in the type the resolution works in.
    #
    # Not `ENV` itself as the default: `ENV` is not a `Hash`, and a default
    # argument is only checked where the method is actually called — so
    # `= ENV` sat unobjected until something called `resolve`, and it broke the
    # build rather than failing quietly. Snapshotting also means a resolution
    # cannot observe the environment changing underneath it mid-call.
    private def self.env_snapshot : Hash(String, String?)
      snapshot = Hash(String, String?).new
      ENV.each { |key, value| snapshot[key] = value }
      snapshot
    end
  end
end
