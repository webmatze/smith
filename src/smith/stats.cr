require "./pricing"
require "./session"

module Smith
  # Aggregates what the session store already knows — built purely from the
  # index entries, never loading a transcript. `smith stats` is a read-only
  # view over what `smith sessions` shows per row.
  module Stats
    # One provider/model combination as it appears in the breakdown.
    struct ModelStat
      getter provider : String
      getter model : String
      getter sessions : Int32 = 0
      getter tokens : Int64 = 0_i64

      # nil when the rate is unknown — tokens still count, cost says `n/a`,
      # never a guess (the Pricing rule applies to aggregates too).
      getter cost : Float64? = nil

      def initialize(@provider : String, @model : String)
      end

      def add(usage : LLM::Usage, rate_cost : Float64?) : Nil
        @sessions += 1
        @tokens += usage.prompt_tokens.to_i64 + usage.completion_tokens.to_i64 +
                   usage.cache_creation_tokens.to_i64 + usage.cache_read_tokens.to_i64
        @cost = rate_cost.nil? ? @cost : (@cost || 0.0) + rate_cost
      end

      def key : String
        Pricing.key_for(provider, model)
      end

      def label : String
        "#{provider}/#{model}"
      end
    end

    # The total over all sessions. Entries without recorded usage contribute
    # to the session count and nothing else; entries with an unknown rate
    # contribute tokens but no cost.
    struct Aggregate
      property sessions : Int32 = 0
      property with_usage : Int32 = 0
      property prompt_tokens : Int64 = 0_i64
      property completion_tokens : Int64 = 0_i64
      property cache_creation_tokens : Int64 = 0_i64
      property cache_read_tokens : Int64 = 0_i64

      # nil when no session has a known rate — the honest answer is `n/a`,
      # not zero. Only Stats.aggregate writes these; everyone else reads.
      property cost : Float64? = nil
      property by_model : Array(ModelStat) = Array(ModelStat).new

      def total_tokens : Int64
        prompt_tokens + completion_tokens + cache_creation_tokens + cache_read_tokens
      end

      def cached_tokens : Int64
        cache_creation_tokens + cache_read_tokens
      end
    end

    def self.aggregate(entries : Array(Session::IndexEntry), overrides : Pricing::Overrides? = nil) : Aggregate
      agg = Aggregate.new
      models = Hash(String, ModelStat).new

      entries.each do |entry|
        agg.sessions += 1

        usage = entry.usage
        provider = entry.provider
        model = entry.model
        next if usage.nil? || provider.nil? || model.nil?

        agg.with_usage += 1
        agg.prompt_tokens += usage.prompt_tokens
        agg.completion_tokens += usage.completion_tokens
        agg.cache_creation_tokens += usage.cache_creation_tokens
        agg.cache_read_tokens += usage.cache_read_tokens

        key = Pricing.key_for(provider, model)
        stat = models[key]? || ModelStat.new(provider, model)
        stat.add(usage, Pricing.estimate(usage, provider, model, overrides))
        # ModelStat is a struct: write the updated copy back into the hash.
        models[key] = stat
      end

      known = models.values.sum { |s| s.cost || 0.0 }
      agg.cost = known if models.values.any? { |s| !s.cost.nil? }

      # Most-used model first.
      agg.by_model = models.values.sort_by(&.tokens).reverse

      agg
    end
  end
end
