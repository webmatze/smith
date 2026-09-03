require "../spec_helper"
require "../../src/smith/agent"
require "../../src/smith/session"

# Records the model each request was built with. That name is the only place
# the wire learns which model to use, so it is what a switch has to change.
private class ModelRecordingProvider < Smith::LLM::Provider
  getter models = [] of String

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
      [Smith::LLM::ContentBlock.text("ok")]
    )
  end
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
