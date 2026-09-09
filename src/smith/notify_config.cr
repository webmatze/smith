require "toml"

module Smith
  # Resolved configuration for cmux desktop notifications. Pure data: it holds
  # the effective values after config and environment have been merged, and
  # knows nothing about sockets or the wire protocol.
  #
  # Reading the config tier is here for the same reason — a TOML table is data,
  # and turning it into this record involves no environment, no socket and no
  # protocol. Which keeps the callers of the notify subsystem down to one name:
  # `Config` reads a table into this record, and everything downstream hands the
  # record to `Notify`. The environment is somebody else's business.
  #
  # Blank strings are normalised to `nil` so callers can treat "unset" and
  # "explicitly empty" the same way.
  #
  # `enabled` is a `Bool?` for the same reason, and it matters more here than
  # anywhere else in this record: `false` is somebody turning notifications
  # off, `nil` is nobody having said. Only the second one lets the terminal
  # have a say. Collapsing the two would mean a config file that never mentions
  # `[notify]` was read as one that refused it, and no amount of environment
  # could switch them back on.
  record NotifyConfig,
    enabled : Bool? = nil,
    socket_path : String? = nil,
    surface_id : String? = nil,
    workspace_id : String? = nil,
    timeout : Float64 = DEFAULT_TIMEOUT do
    DEFAULT_TIMEOUT = 1.0

    # The `[notify]` section, before the environment has had a say.
    #
    # Blank strings become nil, so `socket_path = ""` in a config file is the
    # same as the key not being there — otherwise the empty value would shadow
    # the environment with nothing. A value of the wrong type is ignored rather
    # than raised on, because `socket_path = true` is a typo and not a reason
    # for smith to refuse to start.
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

    # One rule for both tiers, so "unset" and "explicitly empty" cannot come
    # apart between the config file and the environment: a whitespace-only
    # value is an absent one, wherever it was read from.
    def self.normalize(value : String?) : String?
      return nil if value.nil?
      stripped = value.strip
      stripped.empty? ? nil : stripped
    end

    # True when a socket path was resolved. Without one there is no cmux
    # daemon to talk to, so notifications degrade to a no-op.
    def socket? : Bool
      !@socket_path.nil?
    end

    # True when notifications were asked for. `nil` is not: nobody asked, and
    # this record on its own has nothing to go on.
    def enabled? : Bool
      @enabled == true
    end

    # True when everything needed to actually deliver is present.
    def deliverable? : Bool
      enabled? && socket?
    end

    private def self.setting(table : Hash(String, TOML::Any)?, key : String) : TOML::Any?
      table.try(&.[key]?)
    end

    # TOML writes `timeout = 2` as an integer and `timeout = 0.5` as a float,
    # and both are the same statement — `as_f?` reads either.
    private def self.float_setting(table : Hash(String, TOML::Any)?, key : String) : Float64?
      setting(table, key).try(&.as_f?)
    end
  end
end
