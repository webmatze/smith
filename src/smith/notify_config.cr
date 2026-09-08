module Smith
  # Resolved configuration for cmux desktop notifications. Pure data: it holds
  # the effective values after config and environment have been merged, and
  # knows nothing about sockets or the wire protocol.
  #
  # Blank strings are normalised to `nil` so callers can treat "unset" and
  # "explicitly empty" the same way.
  #
  # `enabled` is a `Bool?` for the same reason, and it matters more here than
  # anywhere else in this record: `false` is somebody turning notifications
  # off, `nil` is nobody having said. Only the second one lets the terminal
  # have a say — see `CmuxClient.resolve`. Collapsing the two would mean a
  # config file that never mentions `[notify]` was read as one that refused
  # it, and no amount of environment could switch them back on.
  record NotifyConfig,
    enabled : Bool? = nil,
    socket_path : String? = nil,
    surface_id : String? = nil,
    workspace_id : String? = nil,
    timeout : Float64 = 1.0 do
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
  end
end
