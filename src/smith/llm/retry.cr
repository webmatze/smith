module Smith::LLM
  class Retry
    # Marks an error that must not be retried whatever its type. Streaming
    # uses it once the first delta has reached the screen: replaying the call
    # would print the same text twice.
    class Fatal < Exception
      getter inner : Exception

      def initialize(@inner : Exception)
        super(@inner.message)
      end
    end

    struct Config
      property max_retries : Int32
      property initial_delay : Time::Span
      property max_delay : Time::Span
      property backoff_factor : Float64

      def initialize(
        @max_retries : Int32 = 3,
        @initial_delay : Time::Span = 1.second,
        @max_delay : Time::Span = 30.seconds,
        @backoff_factor : Float64 = 2.0,
      )
      end
    end

    def self.with_retry(config : Config = Config.new, &block : -> T) : T forall T
      retries = 0
      delay = config.initial_delay

      loop do
        begin
          return yield
        rescue ex : Exception
          # Unwrap so callers see the original failure, not the marker.
          raise ex.inner if ex.is_a?(Fatal)

          retries += 1
          if retries > config.max_retries || !retryable?(ex)
            raise ex
          end

          sleep delay
          delay = {delay * config.backoff_factor, config.max_delay}.min
        end
      end
    end

    private def self.retryable?(ex : Exception) : Bool
      case ex
      when IO::TimeoutError
        # An elapsed timeout is a deliberate give-up, not a transient blip.
        # Retrying it would multiply the wait the user configured — with the
        # 120s default and 3 retries that is roughly 8 minutes of silence.
        # Must stay above the IO::Error branch, which would otherwise match it.
        false
      when ResponseError
        status = ex.status_code
        status == 429 || status >= 500
      when Socket::Error, IO::Error
        true
      else
        false
      end
    end
  end
end
