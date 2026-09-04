require "../spec_helper"
require "../../src/smith/cli"

# Answers anything, so a spec can take a real turn without a provider.
private class StubProvider < Smith::LLM::Provider
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
      [Smith::LLM::ContentBlock.text("ok")]
    )
  end
end

# The loop's write-back is private, and it is the whole seam this fix lives in:
# every place that persists calls this one method, which is why the guard is
# here and not at whichever call site was noticed first. Reopening the class is
# what lets the spec drive the real thing; a copy of `persist` written out in
# the spec would pass whatever the CLI did.
class Smith::CLI
  def persist_for_spec(session_data : Smith::Session::Data, agent : Smith::Agent) : Nil
    persist(session_data, agent)
  end

  def store_for_spec : Smith::Session::Store
    @session_store
  end
end

# A CLI whose session store, config and catalogs are all under a throwaway
# SMITH_HOME, so nothing here reads or writes the developer's real ~/.smith.
private def with_cli(&)
  temp_dir = File.join(Dir.tempdir, "smith_clear_persist_#{Random::Secure.hex(4)}")
  previous = ENV["SMITH_HOME"]?
  ENV["SMITH_HOME"] = temp_dir

  begin
    yield Smith::CLI.new([] of String)
  ensure
    previous ? (ENV["SMITH_HOME"] = previous) : ENV.delete("SMITH_HOME")
    remove_tree(temp_dir)
  end
end

# What `build_agent` does: the agent is handed the session's own message array.
private def agent_on(session : Smith::Session::Data) : Smith::Agent
  Smith::Agent.new(
    provider: StubProvider.new,
    model: session.model,
    messages: session.messages,
    context_ratio: session.context_ratio
  )
end

private def two_message_session(store : Smith::Session::Store) : Smith::Session::Data
  session = store.create(model: "claude-sonnet-5", provider: "anthropic")
  session.messages << Smith::LLM::Message.user("remember this sentence")
  session.messages << Smith::LLM::Message.assistant("noted")
  store.save(session)
  session
end

describe "a session abandoned after /clear" do
  it "keeps its transcript when the loop persists on the way to another one" do
    # The sequence from the report: resume a session with two messages, /clear,
    # then /resume somewhere else — which persists the session being left
    # before it switches.
    with_cli do |cli|
      store = cli.store_for_spec
      session = two_message_session(store)

      agent = agent_on(session)
      agent.clear!
      cli.persist_for_spec(session, agent)

      # The record itself…
      store.load(session.id).messages.size.should eq(2)
      # …and the index row `smith sessions` and `/sessions` list from, which
      # was emptied along with it.
      store.list.first.message_count.should eq(2)
      # And in memory, so the loop that carries on holds what disk holds.
      session.messages.size.should eq(2)
    end
  end

  it "keeps the todo list and the calibration that belong to that transcript" do
    with_cli do |cli|
      store = cli.store_for_spec
      session = two_message_session(store)
      session.todos = [Smith::TodoList::Item.new("finish the parser", Smith::TodoList::Status::Pending)]
      # What the provider last said the estimate was off by. It was measured
      # against the transcript being kept, so it has to be kept with it.
      session.context_ratio = 1.4
      store.save(session)

      # `/clear` empties the CLI's todo list too and puts the ratio back to
      # neutral; a fresh CLI's list is empty for the same reason.
      agent = agent_on(session)
      agent.clear!
      agent.context_ratio.should eq(1.0)

      cli.persist_for_spec(session, agent)

      reloaded = store.load(session.id)
      reloaded.todos.size.should eq(1)
      reloaded.context_ratio.should eq(1.4)
    end
  end

  it "records the fresh conversation as soon as a turn takes one" do
    # The other half of the reading: /clear still starts over. It is the turn
    # that writes the new conversation over the old one, not the /clear.
    with_cli do |cli|
      store = cli.store_for_spec
      session = two_message_session(store)

      agent = agent_on(session)
      agent.clear!
      agent.send("a new start")

      cli.persist_for_spec(session, agent)

      reloaded = store.load(session.id)
      reloaded.messages.size.should eq(2)
      reloaded.messages.first.content.first.text.should eq("a new start")
    end
  end

  it "still records an ordinary turn" do
    with_cli do |cli|
      store = cli.store_for_spec
      session = store.create(model: "claude-sonnet-5", provider: "anthropic")

      agent = agent_on(session)
      agent.send("hello")
      cli.persist_for_spec(session, agent)

      store.load(session.id).messages.size.should eq(2)
      store.list.first.message_count.should eq(2)
    end
  end
end

describe "Agent#cleared?" do
  it "is false until /clear, true after it, and false again from the next turn" do
    # Deliberately not `messages.empty?`: a session that was never used is
    # empty too, and the guard has to tell that apart from a cleared one.
    agent = Smith::Agent.new(provider: StubProvider.new, model: "claude-sonnet-5")
    agent.cleared?.should be_false

    agent.clear!
    agent.cleared?.should be_true

    agent.send("a new start")
    agent.cleared?.should be_false
  end
end
