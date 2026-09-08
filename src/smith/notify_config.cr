module Smith
  # Resolved configuration for cmux desktop notifications. Pure data: it holds
  # the effective values after config and environment have been merged, and
  # knows nothing about sockets or the wire protocol.
  #
  # Blank strings are normalised to `nil` so callers can treat "unset" and
  # "explicitly empty" the same way.
  record NotifyConfig,
    enabled : Bool = false,
    socket_path : String? = nil,
    surface_id : String? = nil,
    workspace_id : String? = nil,
    timeout : Float64 = 1.0 do
    # True when a socket path was resolved. Without one there is no cmux
    # daemon to talk to, so notifications degrade to a no-op.
    def socket? : Bool
      !@socket_path.nil?
    end

    # True when everything needed to actually deliver is present.
    def deliverable? : Bool
      @enabled && socket?
    end
  end
end
