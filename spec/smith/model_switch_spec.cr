require "../spec_helper"
require "../../src/smith/agent"
require "../../src/smith/session"

# Records the model each request was built with. That name is the only place
# the wire learns which model to use, so it is what a switch has to change.
private class ModelRecordingProvider < Smith::LLM::Provider
  getter models = [] of String

  # Billed to the caller for the next answer, so a spec can price two turns
  # differently the way two models do.
  property next_usage : Smith::LLM::Usage? = nil

  def name : String
    "anthropic"
  end

  def default_model : String
    "claude-sonnet-5"
  end

  def complete(request : Smith::LLM::Request) : Smith::LLM::Response
    @models << request.model
    Smith::LLM::Response.new(
      "resp_#{@models.size}",
      request.model,
      [Smith::LLM::ContentBlock.text("ok")],
      usage: @next_usage
    )
  end
end

# $15 and $1 per million input tokens — an expensive model and a cheap one.
private DEAR  = Smith::Pricing::Rates.new(input: 15.0, output: 15.0)
private CHEAP = Smith::Pricing::Rates.new(input: 1.0, output: 1.0)

private def prompt_tokens(n : Int32) : Smith::LLM::Usage
  Smith::LLM::Usage.new(prompt_tokens: n, completion_tokens: 0, total_tokens: n)
end

private def budgeted(provider, limit : Float64, rates : Smith::Pricing::Rates)
  Smith::Agent.new(provider: provider, model: "claude-opus-5", cost_limit_usd: limit, rates: rates)
end

private def budget_events(agent) : Array(Smith::Events::BudgetExceeded)
  seen = [] of Smith::Events::BudgetExceeded
  agent.on_event { |event| seen << event if event.is_a?(Smith::Events::BudgetExceeded) }
  seen
end

describe "switching the model inside a running session" do
  it "sends the new model from the next request onward" do
    provider = ModelRecordingProvider.new
    agent = Smith::Agent.new(provider: provider, model: "claude-sonnet-5")

    agent.send("before")
    # What `/model <name>` does: the client is untouched, only the name is.
    agent.model = "claude-opus-5"
    agent.send("after")

    provider.models.should eq(["claude-sonnet-5", "claude-opus-5"])
    # The same client served both, which is the point of switching this way.
    agent.provider.should be(provider)
  end

  it "persists the new model into the session and its index row" do
    temp_dir = File.join(Dir.tempdir, "smith_model_switch_#{Random::Secure.hex(4)}")

    begin
      store = Smith::Session::Store.new(base_dir: temp_dir)
      session = store.create(model: "claude-sonnet-5", provider: "anthropic")
      session.messages << Smith::LLM::Message.user("hello")
      store.save(session)

      session.model = "claude-opus-5"
      store.save(session)

      # `smith resume` reads the session file…
      store.load(session.id).model.should eq("claude-opus-5")
      # …and `smith sessions` the index row, rebuilt from the same field.
      store.list.first.model.should eq("claude-opus-5")
    ensure
      FileUtils.rm_rf(temp_dir) if Dir.exists?(temp_dir)
    end
  end
end

describe "a cost budget across a model switch" do
  it "does not un-spend money when the switch is to a cheaper model" do
    provider = ModelRecordingProvider.new
    agent = budgeted(provider, 1.00, DEAR)
    events = budget_events(agent)

    # 60k tokens at $15/M — $0.90 of a $1.00 budget, gone for good.
    provider.next_usage = prompt_tokens(60_000)
    agent.send("expensive turn")
    agent.spent_usd.should be_close(0.90, 0.0001)
    events.should be_empty

    agent.model = "claude-haiku-4-5"
    agent.rates = CHEAP

    # 150k tokens at $1/M is $0.15, which takes the run past the limit.
    # Re-pricing the whole session at the cheap rate would have said $0.21
    # and handed back headroom for money already spent.
    provider.next_usage = prompt_tokens(150_000)
    agent.send("cheap turn")

    agent.spent_usd.should be_close(1.05, 0.0001)
    events.size.should eq(1)
    events.first.spent_usd.should be_close(1.05, 0.0001)
  end

  it "does not end a run over money it never spent when the switch is dearer" do
    provider = ModelRecordingProvider.new
    agent = budgeted(provider, 1.00, CHEAP)
    events = budget_events(agent)

    # 100k tokens at $1/M — a tenth of the budget.
    provider.next_usage = prompt_tokens(100_000)
    agent.send("cheap turn")

    agent.model = "claude-opus-5"
    agent.rates = DEAR

    # 10k at $15/M is $0.15, for $0.25 all told. Re-pricing the whole session
    # at the dear rate would have said $1.65 and stopped the run dead.
    provider.next_usage = prompt_tokens(10_000)
    agent.send("expensive turn")

    agent.spent_usd.should be_close(0.25, 0.0001)
    events.should be_empty
  end

  it "counts an unpriced stretch as nothing without forgetting what came before" do
    provider = ModelRecordingProvider.new
    agent = budgeted(provider, 1.00, DEAR)
    events = budget_events(agent)

    provider.next_usage = prompt_tokens(60_000)
    agent.send("priced turn")

    # A model nobody has a price for: the CLI says so, and the turn adds
    # nothing rather than a guess — but $0.90 is still spent.
    agent.rates = nil
    provider.next_usage = prompt_tokens(500_000)
    agent.send("unpriced turn")

    agent.spent_usd.should be_close(0.90, 0.0001)
    events.should be_empty
  end

  it "enforces nothing when no rate was ever known" do
    provider = ModelRecordingProvider.new
    agent = Smith::Agent.new(provider: provider, model: "mystery", cost_limit_usd: 0.0, rates: nil)
    events = budget_events(agent)

    provider.next_usage = prompt_tokens(1_000_000)
    agent.send("unpriced")

    agent.spent_usd.should eq(0.0)
    events.should be_empty
  end

  it "starts a resumed session at zero spend, as the token counter does" do
    # build_agent passes no usage, so Agent#cumulative_usage starts at zero on
    # a resume and the budget has always been per-run. The accumulator has to
    # start the same way or a switch would silently change that.
    provider = ModelRecordingProvider.new
    agent = budgeted(provider, 1.00, DEAR)

    agent.spent_usd.should eq(0.0)
    agent.cumulative_usage.total_tokens.should eq(0)
  end
end

describe "clearing the context before a model switch" do
  it "leaves the session's own transcript alone" do
    # build_agent hands the agent `session_data.messages` itself, so an
    # in-place clear used to empty the session too — and the save that /model
    # does would then write that emptied record over what was on disk.
    session = Smith::Session::Data.new(id: "session-x", cwd: "/tmp", model: "claude-sonnet-5", provider: "anthropic")
    session.messages << Smith::LLM::Message.user("remember this sentence")

    agent = Smith::Agent.new(provider: ModelRecordingProvider.new, model: "claude-sonnet-5", messages: session.messages)
    agent.clear!

    agent.messages.should be_empty
    session.messages.size.should eq(1)
  end

  it "survives the round trip to disk that a switch triggers" do
    temp_dir = File.join(Dir.tempdir, "smith_clear_switch_#{Random::Secure.hex(4)}")

    begin
      store = Smith::Session::Store.new(base_dir: temp_dir)
      session = store.create(model: "claude-sonnet-5", provider: "anthropic")
      session.messages << Smith::LLM::Message.user("remember this sentence")
      store.save(session)

      agent = Smith::Agent.new(provider: ModelRecordingProvider.new, model: "claude-sonnet-5", messages: session.messages)
      agent.clear!

      # What /model writes: the model, and nothing else the agent is holding.
      session.model = "claude-opus-5"
      store.save(session)

      reloaded = store.load(session.id)
      reloaded.model.should eq("claude-opus-5")
      reloaded.messages.size.should eq(1)
    ensure
      FileUtils.rm_rf(temp_dir) if Dir.exists?(temp_dir)
    end
  end
end
