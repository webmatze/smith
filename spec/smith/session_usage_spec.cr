require "../spec_helper"
require "../../src/smith/cli"

# Bills every turn the same, so a total is a turn count times a constant and a
# spec can say which run a missing token belongs to. A provider that reported
# no usage at all would let both the bug and the fix pass.
private TURN_USAGE = Smith::LLM::Usage.new(prompt_tokens: 100, completion_tokens: 20, total_tokens: 120)

private class BillingProvider < Smith::LLM::Provider
  def name : String
    "anthropic"
  end

  def default_model : String
    "claude-sonnet-5"
  end

  def complete(request : Smith::LLM::Request) : Smith::LLM::Response
    Smith::LLM::Response.new(
      "resp_1",
      request.model,
      [Smith::LLM::ContentBlock.text("ok")],
      usage: TURN_USAGE
    )
  end
end

# Both halves of the fix are private and belong together: `build_agent` takes
# the baseline at the moment the run's counter is born, `persist` adds the two
# back up. A spec that built an `Agent` by hand would have to set the baseline
# by hand too — which is the fix rewritten in the spec, proving nothing about
# the CLI. Reopening the class drives the real pair.
#
# `persist_for_spec` and `store_for_spec` are the same two lines
# `clear_persist_spec.cr` reopens the class for, written out again rather
# than shared so that either file still runs on its own.
class Smith::CLI
  # The `@session_id =` is not spec scaffolding around the seam: every call
  # site sets it before building an agent, because hooks and the background-job
  # directory are named after the session, and `build_agent` raises without it.
  def build_agent_for_spec(provider : Smith::LLM::Provider, session_data : Smith::Session::Data) : Smith::Agent
    @session_id = session_data.id
    build_agent(provider, session_data)
  end

  def persist_for_spec(session_data : Smith::Session::Data, agent : Smith::Agent) : Nil
    persist(session_data, agent)
  end

  def store_for_spec : Smith::Session::Store
    @session_store
  end

  # These are real turns through the real renderer, which prints what the model
  # said. Pointed at memory so the suite's output stays readable; nothing under
  # test reads it back.
  def silence_output_for_spec : Nil
    @presentation = PlainPresentation.new(Output::HumanRenderer.new(IO::Memory.new))
  end
end

# A CLI whose session store, config and catalogs are all under a throwaway
# SMITH_HOME, so nothing here reads or writes the developer's real ~/.smith.
private def with_cli(&)
  temp_dir = File.join(Dir.tempdir, "smith_session_usage_#{Random::Secure.hex(4)}")
  previous = ENV["SMITH_HOME"]?
  ENV["SMITH_HOME"] = temp_dir

  begin
    cli = Smith::CLI.new([] of String)
    cli.silence_output_for_spec
    yield cli
  ensure
    previous ? (ENV["SMITH_HOME"] = previous) : ENV.delete("SMITH_HOME")
    remove_tree(temp_dir)
  end
end

# One `smith resume`: a fresh CLI reads the session back off disk and builds a
# new agent for it, whose counter starts at zero. Taking the record from the
# store rather than reusing the object in hand is the point — a baseline that
# came from memory would survive a restart that a real one does not.
private def resume(cli : Smith::CLI, id : String) : {Smith::Session::Data, Smith::Agent}
  session = cli.store_for_spec.load(id)
  {session, cli.build_agent_for_spec(BillingProvider.new, session)}
end

private def new_session(cli : Smith::CLI) : {Smith::Session::Data, Smith::Agent}
  session = cli.store_for_spec.create(model: "claude-sonnet-5", provider: "anthropic")
  {session, cli.build_agent_for_spec(BillingProvider.new, session)}
end

# What `smith sessions`, `smith stats` and `smith sessions export` read: the
# index row, not the session file. The report is about that column, so the
# assertion has to be about it.
private def indexed_tokens(cli : Smith::CLI, id : String) : Int32
  entry = cli.store_for_spec.list.find { |row| row.id == id }.not_nil!
  entry.usage.not_nil!.total_tokens
end

private def saved_tokens(cli : Smith::CLI, id : String) : Int32
  cli.store_for_spec.load(id).usage.total_tokens
end

describe "a session's lifetime usage across resumes" do
  it "keeps what earlier runs spent instead of reporting the last one" do
    with_cli do |cli|
      # Run one: two turns.
      session, agent = new_session(cli)
      id = session.id
      2.times do |i|
        agent.send("turn #{i}")
        cli.persist_for_spec(session, agent)
      end
      saved_tokens(cli, id).should eq(240)

      # Run two, resumed: one turn. Before the fix this line wrote 120 over
      # the 240 above.
      session, agent = resume(cli, id)
      agent.send("and again")
      cli.persist_for_spec(session, agent)
      saved_tokens(cli, id).should eq(360)

      # Run three, resumed again — the acceptance criterion is the sum of all
      # three runs, in the index.
      session, agent = resume(cli, id)
      agent.send("once more")
      cli.persist_for_spec(session, agent)

      saved_tokens(cli, id).should eq(480)
      indexed_tokens(cli, id).should eq(480)

      # And the run's own counter is still the run's, which is what
      # `renderer.finish` reports when a run ends and what the fullscreen
      # cost line shows while it is going.
      agent.cumulative_usage.total_tokens.should eq(120)
    end
  end

  it "writes the same total however many times a run persists" do
    # persist runs after *every* turn, and `cumulative_usage` is the run's
    # running total rather than the turn's increment — so `usage +=
    # cumulative_usage` double-counts from turn two onward, and a two-turn
    # spec would not notice on turn one. Three turns, checked after each.
    with_cli do |cli|
      session, agent = new_session(cli)

      agent.send("one")
      cli.persist_for_spec(session, agent)
      saved_tokens(cli, session.id).should eq(120)

      agent.send("two")
      cli.persist_for_spec(session, agent)
      saved_tokens(cli, session.id).should eq(240)

      agent.send("three")
      cli.persist_for_spec(session, agent)
      saved_tokens(cli, session.id).should eq(360)

      # Persisting again without a turn in between must not move it either:
      # the ^C handler and the fullscreen loop's exit both do exactly this.
      cli.persist_for_spec(session, agent)
      saved_tokens(cli, session.id).should eq(360)
    end
  end

  it "gives a session switched to mid-run its own history, and leaves the one left alone" do
    # `/resume` inside the running loop: `activate_session` builds a new agent,
    # so the counter restarts — and the baseline has to restart with it. Taken
    # once at process start instead, the session switched *to* keeps a baseline
    # of zero while its counter starts again, so its whole history is written
    # away by the first turn after the switch.
    with_cli do |cli|
      first, first_agent = new_session(cli)
      first_agent.send("in the first session")
      cli.persist_for_spec(first, first_agent)

      second, _ = new_session(cli)
      3.times { |i| second_agent_turn(cli, second, i) }
      cli.store_for_spec.load(second.id).usage.total_tokens.should eq(360)

      # Now switch to it the way the loop does: persist the one being left,
      # then build an agent for the target.
      cli.persist_for_spec(first, first_agent)
      second, second_agent = resume(cli, second.id)
      second_agent.send("carrying on")
      cli.persist_for_spec(second, second_agent)

      saved_tokens(cli, second.id).should eq(480)
      indexed_tokens(cli, second.id).should eq(480)
      # The session left behind keeps its own, and gains nothing from the
      # other one's counter.
      saved_tokens(cli, first.id).should eq(120)
    end
  end

  it "leaves --max-budget-usd a per-run limit" do
    # The budget runs off `spent_usd`, which the agent counts for itself and
    # which no baseline touches. A resumed session with a long history starts
    # a new run owing nothing, exactly as before.
    with_cli do |cli|
      session, agent = new_session(cli)
      2.times { agent.send("spend a little") }
      cli.persist_for_spec(session, agent)
      saved_tokens(cli, session.id).should eq(240)

      _, resumed = resume(cli, session.id)
      resumed.spent_usd.should eq(0.0)
      resumed.cumulative_usage.total_tokens.should eq(0)
    end
  end

  it "records nothing while the context is cleared, and loses no tokens by it" do
    # `persist` returns early after `/clear` (#105). Nothing is lost: `clear!`
    # leaves `cumulative_usage` alone, no chat command spends a token, and the
    # turn that spent one had already persisted it.
    with_cli do |cli|
      session, agent = new_session(cli)

      agent.send("before the clear")
      cli.persist_for_spec(session, agent)
      saved_tokens(cli, session.id).should eq(120)

      agent.clear!
      cli.persist_for_spec(session, agent)
      saved_tokens(cli, session.id).should eq(120)

      # The next turn ends the cleared window and brings its own tokens with
      # it — including the ones spent before the clear, which the counter
      # never gave up.
      agent.send("a new start")
      cli.persist_for_spec(session, agent)
      saved_tokens(cli, session.id).should eq(240)
    end
  end
end

# A turn on a session whose agent this helper builds and throws away, so the
# switch spec can put three runs' worth of history on disk without holding an
# agent for them.
private def second_agent_turn(cli : Smith::CLI, session : Smith::Session::Data, index : Int32) : Nil
  data = cli.store_for_spec.load(session.id)
  agent = cli.build_agent_for_spec(BillingProvider.new, data)
  agent.send("earlier run #{index}")
  cli.persist_for_spec(data, agent)
end
