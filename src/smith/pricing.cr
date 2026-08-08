require "./llm/types"

module Smith
  # Turns token counts into money.
  #
  # The governing rule: a wrong cost figure is worse than no cost figure. A
  # model the table has never heard of prices as `nil`, which surfaces as
  # `n/a` — never as a plausible-looking guess. Rates go stale as vendors
  # change them, so every entry can be overridden from config.
  module Pricing
    # US dollars per million tokens.
    struct Rates
      getter input : Float64
      getter output : Float64
      getter cache_write : Float64
      getter cache_read : Float64

      # Anthropic charges 1.25x the input rate to write the cache and 0.1x to
      # read it. Both default from `input` so an override only has to state
      # the two rates anyone publishes.
      def initialize(
        @input : Float64,
        @output : Float64,
        cache_write : Float64? = nil,
        cache_read : Float64? = nil,
      )
        @cache_write = cache_write || @input * 1.25
        @cache_read = cache_read || @input * 0.1
      end

      def self.free : Rates
        new(input: 0.0, output: 0.0, cache_write: 0.0, cache_read: 0.0)
      end
    end

    PER_MILLION = 1_000_000.0

    # Only models whose published rates are actually known. Everything else is
    # deliberately absent: `n/a` is the honest answer, and `[pricing]` is there
    # for anyone who knows better.
    TABLE = {
      "anthropic/claude-fable-5"    => Rates.new(input: 10.0, output: 50.0),
      "anthropic/claude-opus-5"     => Rates.new(input: 5.0, output: 25.0),
      "anthropic/claude-opus-4-8"   => Rates.new(input: 5.0, output: 25.0),
      "anthropic/claude-opus-4-7"   => Rates.new(input: 5.0, output: 25.0),
      "anthropic/claude-opus-4-6"   => Rates.new(input: 5.0, output: 25.0),
      "anthropic/claude-sonnet-5"   => Rates.new(input: 3.0, output: 15.0),
      "anthropic/claude-sonnet-4-6" => Rates.new(input: 3.0, output: 15.0),
      "anthropic/claude-haiku-4-5"  => Rates.new(input: 1.0, output: 5.0),
    }

    alias Overrides = Hash(String, Rates)

    def self.key_for(provider : String, model : String) : String
      "#{provider.strip.downcase}/#{model.strip.downcase}"
    end

    def self.rates_for(provider : String, model : String, overrides : Overrides? = nil) : Rates?
      key = key_for(provider, model)

      if configured = overrides.try(&.[key]?)
        return configured
      end

      # A local model costs electricity, not tokens.
      return Rates.free if provider.strip.downcase == "ollama"

      TABLE[key]?
    end

    # nil means "no basis to say" — never zero-as-unknown, which would read as
    # free.
    def self.estimate(
      usage : LLM::Usage,
      provider : String,
      model : String,
      overrides : Overrides? = nil,
    ) : Float64?
      rates = rates_for(provider, model, overrides)
      return nil if rates.nil?

      cost(usage, rates)
    end

    def self.cost(usage : LLM::Usage, rates : Rates) : Float64
      (usage.prompt_tokens * rates.input +
        usage.completion_tokens * rates.output +
        usage.cache_creation_tokens * rates.cache_write +
        usage.cache_read_tokens * rates.cache_read) / PER_MILLION
    end

    # Sub-cent amounts are the common case for a single turn, so they get the
    # extra digits rather than rounding to $0.00.
    def self.format(cost : Float64?) : String
      return "n/a" if cost.nil?
      return "$#{"%.4f" % cost}" if cost > 0.0 && cost < 0.1

      "$#{"%.2f" % cost}"
    end
  end
end
