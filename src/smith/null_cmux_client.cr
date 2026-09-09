require "./cmux_clientable"

module Smith
  # The client for every case where there is nothing to deliver to: cmux
  # notifications are off, no socket was resolved, or the daemon is not there.
  #
  # It exists so the caller does not branch. `Smith::Notify` builds a client
  # and calls `notify` either way, and the difference between "cmux is not
  # running" and "cmux is running" never reaches the code that decides a run
  # is finished and the human should hear about it.
  class NullCmuxClient < CmuxClientable
    def notify(payload : Hash(String, JSON::Any)) : Bool
      false
    end

    def available? : Bool
      false
    end
  end
end
