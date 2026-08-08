require "../spec_helper"
require "../../src/smith/pricing"

private def usage(prompt = 0, completion = 0, cache_write = 0, cache_read = 0)
  Smith::LLM::Usage.new(prompt, completion, prompt + completion, cache_write, cache_read)
end

describe Smith::Pricing do
  it "prices a known model from its published rates" do
    # claude-sonnet-5: $3 / $15 per million.
    cost = Smith::Pricing.estimate(usage(prompt: 1_000_000, completion: 1_000_000), "anthropic", "claude-sonnet-5")

    cost.should_not be_nil
    cost.not_nil!.should be_close(18.0, 0.001)
  end

  it "prices cache writes and reads separately" do
    # Anthropic charges 1.25x to write and 0.1x to read.
    cost = Smith::Pricing.estimate(
      usage(cache_write: 1_000_000, cache_read: 1_000_000),
      "anthropic", "claude-sonnet-5"
    )

    cost.not_nil!.should be_close(3.0 * 1.25 + 3.0 * 0.1, 0.001)
  end

  it "reports nothing rather than guessing at an unknown model" do
    # A wrong number is worse than no number.
    Smith::Pricing.estimate(usage(prompt: 1_000_000), "openai", "some-unreleased-model").should be_nil
  end

  it "charges nothing for a local model" do
    Smith::Pricing.estimate(usage(prompt: 5_000_000), "ollama", "gemma4:latest").should eq(0.0)
  end

  it "prefers a configured rate over the built-in table" do
    overrides = {"anthropic/claude-sonnet-5" => Smith::Pricing::Rates.new(input: 1.0, output: 2.0)}

    cost = Smith::Pricing.estimate(
      usage(prompt: 1_000_000, completion: 1_000_000),
      "anthropic", "claude-sonnet-5", overrides
    )

    cost.not_nil!.should be_close(3.0, 0.001)
  end

  it "prices a model the table has never heard of once it is configured" do
    overrides = {"openai/gpt-5.6-luna" => Smith::Pricing::Rates.new(input: 2.0, output: 8.0)}

    cost = Smith::Pricing.estimate(usage(prompt: 1_000_000), "openai", "gpt-5.6-luna", overrides)

    cost.not_nil!.should be_close(2.0, 0.001)
  end

  it "matches the model regardless of case" do
    Smith::Pricing.estimate(usage(prompt: 1_000_000), "Anthropic", "Claude-Sonnet-5").should_not be_nil
  end

  it "says n/a when there is no price to state" do
    Smith::Pricing.format(nil).should eq("n/a")
    Smith::Pricing.format(0.0).should eq("$0.00")
    Smith::Pricing.format(0.01234).should eq("$0.0123")
    Smith::Pricing.format(2.5).should eq("$2.50")
  end
end
