require "http/client"
require "uri"
require "../config"

module Smith::LLM
  class ResponseError < Exception
    getter status_code : Int32

    def initialize(@status_code : Int32, message : String)
      super(message)
    end
  end

  # How long a provider will wait before giving up on a request.
  #
  # Note that an elapsed read timeout is *not* retried (see Retry.retryable?),
  # so `read` is genuinely the longest smith will sit on a single call.
  struct Timeouts
    getter connect : Time::Span
    getter read : Time::Span

    def initialize(@connect : Time::Span, @read : Time::Span)
    end

    # What the [http] config section yields, which is whole seconds.
    def self.from_seconds(connect_seconds : Int32, read_seconds : Int32) : Timeouts
      new(connect_seconds.seconds, read_seconds.seconds)
    end

    # Mirrors the [http] defaults in Smith::Config so there is only ever one
    # source of truth for these numbers.
    def self.default : Timeouts
      from_seconds(Smith::Config::DEFAULT_CONNECT_TIMEOUT, Smith::Config::DEFAULT_READ_TIMEOUT)
    end
  end

  abstract class Provider
    @timeouts : Timeouts = Timeouts.default

    getter timeouts : Timeouts

    abstract def name : String
    abstract def default_model : String
    abstract def complete(request : Request) : Response

    # Every provider builds its HTTP client through here, so no request can
    # accidentally go out without timeouts attached.
    protected def build_client(uri : URI) : HTTP::Client
      client = HTTP::Client.new(uri)
      client.connect_timeout = @timeouts.connect
      client.read_timeout = @timeouts.read
      client
    end
  end
end
