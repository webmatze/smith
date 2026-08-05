require "../../spec_helper"
require "../../../src/smith/llm/anthropic"

describe Smith::LLM::Anthropic do
  it "initializes with API key and default model" do
    provider = Smith::LLM::Anthropic.new(api_key: "dummy_key")
    provider.name.should eq("anthropic")
    provider.default_model.should eq("claude-sonnet-5")
    provider.api_key.should eq("dummy_key")
  end

  it "raises ArgumentError when API key is missing" do
    ENV.delete("ANTHROPIC_API_KEY")
    expect_raises(ArgumentError) do
      Smith::LLM::Anthropic.new(api_key: "")
    end
  end
end
