require "../spec_helper"
require "../../src/smith/output"
require "../../src/smith/pricing"

# Answers with one tool call per turn, so the loop keeps going until something
# else stops it.
private class LoopingProvider < Smith::LLM::Provider
  getter calls = 0

  def initialize(@per_turn : Smith::LLM::Usage)
  end

  def name : String
    "anthropic"
  end

  def default_model : String
    "claude-sonnet-5"
  end

  def complete(request : Smith::LLM::Request) : Smith::LLM::Response
    @calls += 1
    blocks = [
      Smith::LLM::ContentBlock.tool_use("call_#{@calls}", "glob", JSON.parse(%({"pattern": "*.cr"}))),
    ]
    Smith::LLM::Response.new("resp_#{@calls}", request.model, blocks, usage: @per_turn)
  end
end

private def budgeted_agent(provider, limit : Float64?, rates : Smith::Pricing::Rates?)
  Smith::Agent.new(
    provider: provider,
    registry: Smith::Tools::Registry.default,
    model: "claude-sonnet-5",
    cost_limit_usd: limit,
    rates: rates
  )
end

describe "a run under a cost budget" do
  it "stops once the estimate reaches the limit" do
    # $3/1M input: 500k prompt tokens per turn is $1.50 a turn.
    provider = LoopingProvider.new(Smith::LLM::Usage.new(500_000, 0, 500_000))
    agent = budgeted_agent(provider, 2.0, Smith::Pricing::Rates.new(input: 3.0, output: 15.0))

    exceeded = [] of Smith::Events::BudgetExceeded
    agent.on_event { |event| exceeded << event if event.is_a?(Smith::Events::BudgetExceeded) }

    agent.send("keep going")

    exceeded.size.should eq(1)
    exceeded.first.limit_usd.should eq(2.0)
    exceeded.first.spent_usd.should be_close(3.0, 0.001)
    # Two calls: the first spends $1.50, the second crosses the limit and is
    # the last one made.
    provider.calls.should eq(2)
  end

  it "does not stop a run that stays under the limit" do
    provider = LoopingProvider.new(Smith::LLM::Usage.new(1_000, 0, 1_000))
    agent = budgeted_agent(provider, 100.0, Smith::Pricing::Rates.new(input: 3.0, output: 15.0))

    exceeded = false
    agent.on_event { |event| exceeded = true if event.is_a?(Smith::Events::BudgetExceeded) }

    agent.send("keep going")

    exceeded.should be_false
  end

  it "cannot enforce a budget it has no prices for" do
    # The CLI warns about this; the agent simply does not pretend to enforce.
    provider = LoopingProvider.new(Smith::LLM::Usage.new(500_000, 0, 500_000))
    agent = budgeted_agent(provider, 0.01, nil)

    exceeded = false
    agent.on_event { |event| exceeded = true if event.is_a?(Smith::Events::BudgetExceeded) }

    agent.send("keep going")

    exceeded.should be_false
  end
end

describe "the exit code" do
  it "separates a spent budget from a failed turn" do
    renderer = Smith::Output::JsonRenderer.new(IO::Memory.new, IO::Memory.new)
    renderer.exit_code.should eq(0)

    renderer.handle(Smith::Events::BudgetExceeded.new(spent_usd: 3.0, limit_usd: 2.0))
    renderer.exit_code.should eq(2)
  end

  it "still reports a failure as a failure" do
    renderer = Smith::Output::JsonRenderer.new(IO::Memory.new, IO::Memory.new)
    renderer.handle(Smith::Events::TurnError.new("boom"))

    renderer.exit_code.should eq(1)
  end
end
