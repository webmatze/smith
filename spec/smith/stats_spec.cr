require "../spec_helper"
require "../../src/smith/stats"
require "../../src/smith/session"

# A store whose entries carry usage, provider and model — the shape the real
# index.json has after any run that talked to a provider.
module StatsSpecHelper
  def self.entry(id : String, provider : String, model : String, usage : Smith::LLM::Usage?)
    now = Time.local
    Smith::Session::IndexEntry.new(
      id: id,
      created_at: now,
      updated_at: now,
      first_prompt: "prompt for #{id}",
      message_count: 4,
      provider: provider,
      model: model,
      usage: usage
    )
  end
end

describe Smith::Stats do
  it "totals tokens across known and unknown models" do
    entries = [
      StatsSpecHelper.entry("s1", "anthropic", "claude-opus-5", Smith::LLM::Usage.new(1_000, 200, 1_200)),
      StatsSpecHelper.entry("s2", "anthropic", "claude-opus-5", Smith::LLM::Usage.new(500, 100, 600)),
      StatsSpecHelper.entry("s3", "example", "mystery-model", Smith::LLM::Usage.new(3_000, 300, 3_300)),
    ]

    agg = Smith::Stats.aggregate(entries)

    agg.sessions.should eq(3)
    agg.with_usage.should eq(3)
    agg.prompt_tokens.should eq(4_500_i64)
    agg.completion_tokens.should eq(600_i64)
    agg.total_tokens.should eq(5_100_i64)

    agg.by_model.size.should eq(2)
    agg.by_model.first.tokens.should eq(3_300_i64) # mystery model is largest
    agg.by_model.first.cost.should be_nil          # unknown rate: never a guess
  end

  it "prices known models through the pricing table and overrides" do
    entries = [
      StatsSpecHelper.entry("s1", "anthropic", "claude-opus-5", Smith::LLM::Usage.new(1_000_000, 0, 1_000_000)),
    ]

    agg = Smith::Stats.aggregate(entries)
    agg.cost.should eq(5.0) # opus-5 input rate is $5/M

    overrides = Smith::Pricing::Overrides{
      "anthropic/claude-opus-5" => Smith::Pricing::Rates.new(input: 10.0, output: 50.0),
    }
    Smith::Stats.aggregate(entries, overrides).cost.should eq(10.0)
  end

  it "keeps cost nil when no session has a known rate" do
    entries = [
      StatsSpecHelper.entry("s1", "example", "mystery-model", Smith::LLM::Usage.new(100, 10, 110)),
    ]

    agg = Smith::Stats.aggregate(entries)
    agg.total_tokens.should eq(110_i64) # tokens still count
    agg.cost.should be_nil              # ...but the total says n/a, not $0
  end

  it "counts sessions without usage but does not pretend they have tokens" do
    entries = [
      StatsSpecHelper.entry("legacy", "anthropic", "claude-opus-5", nil),
    ]

    agg = Smith::Stats.aggregate(entries)
    agg.sessions.should eq(1)
    agg.with_usage.should eq(0)
    agg.total_tokens.should eq(0_i64)
    agg.cost.should be_nil
  end

  it "handles an empty store" do
    agg = Smith::Stats.aggregate(Array(Smith::Session::IndexEntry).new)
    agg.sessions.should eq(0)
    agg.total_tokens.should eq(0_i64)
    agg.cost.should be_nil
    agg.by_model.should be_empty
  end

  it "is read-only over the store it aggregates from" do
    temp_dir = File.join(Dir.tempdir, "smith_stats_test_#{Random::Secure.hex(4)}")
    begin
      store = Smith::Session::Store.new(base_dir: temp_dir)
      session = store.create(model: "claude-opus-5", provider: "anthropic", cwd: "/tmp")
      session.messages << Smith::LLM::Message.user("hello")
      session.usage = Smith::LLM::Usage.new(100, 10, 110)
      store.save(session)

      index_before = File.read(store.index_path)

      agg = Smith::Stats.aggregate(store.list)
      agg.sessions.should eq(1)
      agg.cost.should eq(0.00075) # 100 prompt @ $5/M + 10 completion @ $25/M

      File.read(store.index_path).should eq(index_before)
    ensure
      FileUtils.rm_rf(temp_dir) if Dir.exists?(temp_dir)
    end
  end
end
