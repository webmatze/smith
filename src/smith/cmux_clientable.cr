require "json"

module Smith
  # The seam `Smith::Notify` talks to: something that can hand a cmux
  # notification payload to a cmux daemon.
  #
  # Deliberately the whole surface. It exposes no socket, no path and no
  # protocol, so neither the caller nor the specs need to know which one the
  # real implementation happens to speak — and the null one can keep pretending
  # there is a daemon at all.
  abstract class CmuxClientable
    # Hand a ready-made notification payload to cmux.
    #
    # `payload` is what goes over the wire, keys and all — implementations only
    # transport it. Returns true when cmux accepted it, false when it did not
    # or when there was nothing to accept. A failure here is never an
    # exception: notification delivery must not be able to take a run down.
    abstract def notify(payload : Hash(String, JSON::Any)) : Bool

    # True when there is somewhere to deliver to. Used for diagnostics, never
    # as a precondition — `notify` on a client that answers false is a no-op,
    # not an error.
    abstract def available? : Bool
  end
end
