require "../../spec_helper"
require "../../../src/smith/llm/ollama"

describe Smith::LLM::Ollama do
  it "initializes with default host and model" do
    provider = Smith::LLM::Ollama.new
    provider.name.should eq("ollama")
    provider.host.should eq("http://localhost:11434")
    provider.default_model.should eq("gemma4:latest")
  end

  it "accepts custom host and model" do
    provider = Smith::LLM::Ollama.new(host: "http://127.0.0.1:11434/", default_model: "gemma4:12b")
    provider.host.should eq("http://127.0.0.1:11434")
    provider.default_model.should eq("gemma4:12b")
  end
end
