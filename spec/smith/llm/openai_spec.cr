require "../../spec_helper"
require "../../../src/smith/llm/openai"

describe Smith::LLM::OpenAI do
  it "initializes with API key and default model" do
    provider = Smith::LLM::OpenAI.new(api_key: "dummy_key")
    provider.name.should eq("openai")
    provider.default_model.should eq("gpt-4o")
    provider.api_key.should eq("dummy_key")
  end

  it "raises ArgumentError when API key is missing" do
    ENV.delete("OPENAI_API_KEY")
    expect_raises(ArgumentError) do
      Smith::LLM::OpenAI.new(api_key: "")
    end
  end
end
