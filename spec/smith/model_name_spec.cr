require "../spec_helper"
require "../../src/smith/model_name"

describe Smith::ModelName do
  it "accepts the shapes real model names come in" do
    [
      "claude-sonnet-5",
      "gpt-5.6-luna",
      "gemma4:latest",
      "anthropic/claude-sonnet-5",
      "qwen/qwen3.8-max",
      # Nothing here knows what ships next week, and that is the point.
      "some-model-released-tomorrow",
    ].each do |name|
      Smith::ModelName.rejection(name).should be_nil
    end
  end

  it "rejects an empty or blank name" do
    Smith::ModelName.rejection("").not_nil!.should contain("cannot be empty")
    Smith::ModelName.rejection("   ").not_nil!.should contain("cannot be empty")
  end

  it "names a provider given by mistake, and points at the restart" do
    reason = Smith::ModelName.rejection("anthropic").not_nil!

    reason.should contain("is a provider, not a model")
    reason.should contain("--provider anthropic")
  end

  it "recognises a provider whatever its case" do
    Smith::ModelName.rejection("OpenAI").not_nil!.should contain("is a provider, not a model")
  end

  it "rejects a sentence" do
    Smith::ModelName.rejection("claude opus 5").not_nil!.should contain("a single word")
  end

  it "rejects a flag" do
    Smith::ModelName.rejection("--provider").not_nil!.should contain("command-line flag")
  end

  it "rejects an absolute path but not a vendor prefix" do
    Smith::ModelName.rejection("/etc/passwd").not_nil!.should contain("path")
    Smith::ModelName.rejection("openai/gpt-5.6-luna").should be_nil
  end

  it "rejects quotes" do
    Smith::ModelName.rejection(%("")).not_nil!.should contain("quotes")
    Smith::ModelName.rejection("it's-a-model").not_nil!.should contain("quotes")
  end

  it "is not an allow-list" do
    # BUILTIN_MODELS is a per-provider default, not a roster. Its values pass,
    # but so does anything else shaped like a name — a list would go stale.
    Smith::Config::BUILTIN_MODELS.each_value do |model|
      Smith::ModelName.rejection(model).should be_nil
    end
  end
end
