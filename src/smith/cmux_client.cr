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
    # In priority order. cmux itself documents `CMUX_SOCKET_PATH`; the other
    # two are the older spellings still found in the wild, so they are checked
    # rather than argued with.
    SOCKET_PATH_KEYS = {"CMUX_SOCKET_PATH", "CMUX_SOCKET", "CMUX"}

    # Values an environment variable can hold that mean "not set" rather than
    # "set to this". A shell that exports `CMUX_SOCKET=` is saying the same
    # thing as one that never exported it, and `CMUX=0` is how a program turns
    # a flag off without unsetting it — in both cases the next tier down gets
    # its say instead.
    FALSEY = {"", "0", "false", "no", "off"}

    DEFAULT_TIMEOUT = 1.0

    # The config tier, before the environment has had a say. Blank strings
    # become nil, so `socket_path = ""` in a config file is the same as the key
    # not being there — otherwise the empty value would shadow the environment
    # with nothing.
    def self.from_table(table : Hash(String, TOML::Any)? = nil) : NotifyConfig
      enabled = setting(table, "enabled").try(&.as_bool?)
      timeout = float_setting(table, "timeout")

      NotifyConfig.new(
        enabled: enabled.nil? ? false : enabled,
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
    def self.resolve(config : NotifyConfig, env : Hash(String, String?) = ENV) : NotifyConfig
      cmux = truthy(env, "CMUX")

      NotifyConfig.new(
        # `CMUX` being *truthy* is cmux announcing "you are inside me", which
        # is the same statement as `enabled = true` — and the one made about
        # the terminal actually in use. A falsey `CMUX` is one rule for every
        # variable: an absent value. It says nothing about notifications, so
        # the config file keeps deciding; turning them off from inside cmux is
        # `enabled = false`, which this honours.
        enabled: cmux.nil? ? config.enabled : true,
        socket_path: socket_path(env, config.socket_path),
        surface_id: presence(env, "CMUX_SURFACE_ID") || config.surface_id,
        workspace_id: presence(env, "CMUX_WORKSPACE_ID") || config.workspace_id,
        timeout: config.timeout
      )
    end

    # Resolve, then build. The one call a caller that is not itself resolving
    # anything needs.
    def self.build(config : NotifyConfig, env : Hash(String, String?) = ENV) : CmuxClientable
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

    private def self.socket_path(env : Hash(String, String?), configured : String?) : String?
      SOCKET_PATH_KEYS.each do |key|
        value = truthy(env, key)
        next if value.nil?
        # `CMUX` is a flag first and a path second: only when it holds
        # something that looks like a location is it read as one.
        next if key == "CMUX" && !value.includes?("/")
        return value
      end

      configured
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
  end
end
