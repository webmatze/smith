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
    # Live thinking chunks, when a provider produces them. A property rather
    # than a second block parameter, so the streaming signature every adapter
    # implements stays as it is.
    property on_thinking : Proc(String, Nil)?

    @timeouts : Timeouts = Timeouts.default

    getter timeouts : Timeouts

    abstract def name : String
    abstract def default_model : String
    abstract def complete(request : Request) : Response

    # Whether an image block can be sent at all. Every provider smith ships
    # with can carry one, so the default is true — but for Ollama that depends
    # on the *model*, which nothing here can see, and a provider added later
    # may not take images at all. What this gates is honest: a provider that
    # says no gets a line of text describing the attachment instead of a
    # request it would reject.
    def supports_images? : Bool
      true
    end

    # PDFs are narrower. Anthropic parses one natively; the OpenAI shape has
    # no equivalent, so everywhere else the answer is to say so and point at
    # `bash` and a real tool, rather than ship a PDF parser inside smith.
    def supports_documents? : Bool
      false
    end

    # Streaming entry point. The default does no streaming at all — it runs
    # complete() and hands the text over in one piece.
    #
    # That default is what makes deltas universal: callers always see them,
    # whether or not the provider streams, so neither the agent loop nor the
    # renderers need a special case. Providers override this; when streaming
    # is switched off they call `super`.
    def complete_streaming(request : Request, &on_delta : String -> Nil) : Response
      deliver_without_streaming(request, on_delta)
    end

    # The non-streaming path, as a named method rather than `super` — Crystal
    # cannot resolve `super` from a method with a captured block.
    protected def deliver_without_streaming(request : Request, on_delta : Proc(String, Nil)) : Response
      response = complete(request)

      response.content.each do |block|
        if block.type.text? && (text = block.text)
          on_delta.call(text) unless text.empty?
        end
      end

      response
    end

    # Every provider builds its HTTP client through here, so no request can
    # accidentally go out without timeouts attached.
    protected def build_client(uri : URI) : HTTP::Client
      client = HTTP::Client.new(uri)
      client.connect_timeout = @timeouts.connect
      client.read_timeout = @timeouts.read
      client
    end

    # POSTs and hands the still-open body to the block, so a reader can consume
    # the stream as it arrives. The read timeout from the client applies per
    # read, so a stalled stream still fails instead of hanging forever.
    #
    # `already_emitted` is checked when something goes wrong: once a delta has
    # reached the caller, the error is wrapped as Retry::Fatal so the request
    # is not replayed and the same text printed twice.
    protected def stream_request(uri : URI, headers : HTTP::Headers, payload : String, provider_label : String, &)
      client = build_client(uri)

      # Crystal otherwise sends `Accept-Encoding: gzip, deflate` and wraps the
      # body in a decompressor. A decompressor needs to accumulate input before
      # it can emit anything, which is exactly the wrong shape for an event
      # stream that is supposed to arrive token by token.
      client.compress = false

      begin
        client.post(uri.request_target, headers: headers, body: payload) do |response|
          unless response.status_code == 200
            raise ResponseError.new(
              response.status_code,
              "#{provider_label} API request failed [#{response.status_code}]: #{response.body_io.gets_to_end}"
            )
          end

          yield response.body_io
        end
      ensure
        client.close
      end
    end
  end
end
