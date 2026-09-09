require "json"
require "./cmux_client"
require "./cmux_clientable"
require "./null_cmux_client"
require "./notify_config"

module Smith
  # Decides that a notification should go out, and what it says. Nothing
  # more: which socket carries it, which verb cmux wants and whether the
  # daemon is even running are the client's business, and this class never
  # asks.
  #
  # It is built once per run from a `CmuxClientable` — the real one when cmux
  # is reachable, `NullCmuxClient` in every other case — so no caller has to
  # branch on "am I inside cmux?". The same line of code works either way and
  # just does nothing when there is nowhere to deliver to.
  class Notify
    # What a payload field may hold. Recursive so extras can carry a small
    # nested value, and narrow enough that a caller passing something
    # unserialisable finds out at compile time rather than at the end of a
    # long run.
    alias Field = String | Int32 | Int64 | Float64 | Bool | Nil | Array(Field) | Hash(String, Field)

    # The discriminant of what kind of message this is. cmux also accepts
    # status lines and progress updates; naming the kind here is what lets one
    # client speak to all of them later without this class growing a second
    # method per message type.
    TYPE = "notification"

    def initialize(@client : CmuxClientable)
    end

    # The one door the rest of smith goes through: hand over the resolved
    # config, get back something that notifies or silently does not. No caller
    # has to ask which client a config deserves, whether a socket is involved
    # or whether cmux is the terminal in use — and so no caller learns the name
    # of anything that knows, which is what keeps "the rest of smith knows
    # none of these three" true rather than approximately true.
    #
    # The resolution lives in `CmuxClient`, not here: this class still knows no
    # environment, no socket and no protocol, and only names the thing that
    # does. A constructor taking a client stays, because that is how a spec
    # hands over a recording one.
    def self.build(config : NotifyConfig) : Notify
      new(CmuxClient.build(config))
    end

    # True when there is somewhere to deliver to. Purely informational — the
    # caller does not need it to call `notify`, and should not skip on it: a
    # no-op is exactly what "not inside cmux" means here.
    def enabled? : Bool
      @client.available?
    end

    # Send a notification. Returns true only when cmux took it; false covers
    # "nowhere to send", "cmux refused" and "something threw", which the
    # caller has no way to tell apart and no reason to.
    #
    # `title` is always sent, even empty — it is the one field a notification
    # is identified by. `subtitle` and `body` are sent only when they say
    # something, because an empty body renders as a gap rather than as nothing.
    #
    # `extra` lands in the payload as given and wins over `type`, `subtitle`
    # and `body`: a caller that wants a different discriminant, or wants a
    # blank body kept, says so here instead of rebuilding the payload. `title`
    # cannot be overridden this way — it is a declared parameter, and Crystal
    # refuses a named argument that repeats one.
    #
    # The splat is untyped and the `Field` restriction is enforced by
    # `to_any` instead. Restricting it here would be the more honest
    # signature, but a typed double splat on a method that also has defaulted
    # arguments cannot be called without naming one — Crystal 1.21 rejects
    # `notify("x")` — and "notify with nothing but a title" is the common case.
    def notify(title : String, subtitle : String? = nil, body : String? = nil, **extra) : Bool
      payload = Hash(String, JSON::Any).new
      payload["type"] = JSON::Any.new(TYPE)
      payload["title"] = JSON::Any.new(title)
      put(payload, "subtitle", subtitle)
      put(payload, "body", body)

      extra.each do |key, value|
        payload[key.to_s] = to_any(value)
      end

      deliver(payload)
    end

    # A client that is not supposed to throw says so in its contract, and a
    # real one that talks to a socket will anyway — the socket can vanish
    # between the check and the write, and cmux can be killed mid-run. Either
    # way this is the last thing a finishing run does, and "the notification
    # failed" must never be the reason a run fails.
    private def deliver(payload : Hash(String, JSON::Any)) : Bool
      @client.notify(payload)
    rescue ex : Exception
      false
    end

    private def put(payload : Hash(String, JSON::Any), key : String, value : String?) : Nil
      return if value.nil?
      stripped = value.strip
      return if stripped.empty?

      payload[key] = JSON::Any.new(stripped)
    end

    # `Field` down to something `JSON::Any` can hold. Written out rather than
    # round-tripped through `to_json` and `JSON.parse` because the recursion
    # has to happen here: an `Array(Field)` or a `Hash(String, Field)` is not
    # itself a JSON type, only its leaves are, and a leaf arrives as an `Int32`
    # where `JSON::Any` wants an `Int64`. A value the alias does not admit is
    # refused where it is passed, which is the point of having the alias.
    private def to_any(value : Field) : JSON::Any
      case value
      when Array
        JSON::Any.new(value.map { |item| to_any(item) })
      when Hash
        JSON::Any.new(value.to_h { |key, item| {key, to_any(item)} })
      when Int32
        JSON::Any.new(value.to_i64)
      else
        # Nil, Bool, Int64, Float64 and String: the scalar half of
        # `JSON::Any::Type`, so they go over as they are. This `else` is a
        # branch rather than the fifth `when` because Crystal cannot prove a
        # recursive alias exhaustive, and an unreachable `raise` would be the
        # less honest of the two ways to say so.
        JSON::Any.new(value)
      end
    end
  end
end
