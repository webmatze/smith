require "../spec_helper"
require "../../src/smith/config"

# Runs the block with SMITH_HOME (and optionally SMITH_PROVIDER/SMITH_MODEL)
# pointed at a throwaway directory, so the developer's real ~/.smith is never
# read or written. Everything is restored afterwards.
private def with_sandbox(env : Hash(String, String?) = Hash(String, String?).new, &)
  temp_dir = File.join(Dir.tempdir, "smith_config_test_#{Random::Secure.hex(4)}")
  home_dir = File.join(temp_dir, "smith-home")
  FileUtils.mkdir_p(home_dir)

  overrides = {"SMITH_HOME" => home_dir.as(String?)}.merge(env)
  previous = overrides.keys.to_h { |k| {k, ENV[k]?} }

  overrides.each do |key, value|
    if value
      ENV[key] = value
    else
      ENV.delete(key)
    end
  end

  begin
    yield temp_dir, home_dir
  ensure
    previous.each do |key, value|
      if value
        ENV[key] = value
      else
        ENV.delete(key)
      end
    end
    FileUtils.rm_rf(temp_dir) if Dir.exists?(temp_dir)
  end
end

# A project dir that looks like a git root, so the upward walk stops there
# instead of escaping into the real repository.
private def make_project(temp_dir : String, config : String? = nil) : String
  project = File.join(temp_dir, "project")
  FileUtils.mkdir_p(File.join(project, ".git"))

  if config
    FileUtils.mkdir_p(File.join(project, ".smith"))
    File.write(File.join(project, ".smith", "config.toml"), config)
  end

  project
end

describe Smith::Config do
  it "falls back to built-in defaults when no config file exists" do
    with_sandbox({"SMITH_PROVIDER" => nil, "SMITH_MODEL" => nil}) do |temp_dir, _home|
      project = make_project(temp_dir)
      config = Smith::Config.load(project)

      config.sources.should be_empty
      config.provider.should eq("openrouter")
      config.model_for("openrouter").should eq("qwen/qwen3.8-max")
      config.model_for("anthropic").should eq("claude-sonnet-5")
      config.ollama_host.should eq("http://localhost:11434")
      config.http.connect_timeout.should eq(10)
      config.http.read_timeout.should eq(120)
      config.approval.mode.should eq("prompt")
      config.approval.allowlist.should be_empty
      config.context.max_tokens.should eq(120_000)
    end
  end

  it "reads the global config" do
    with_sandbox({"SMITH_PROVIDER" => nil, "SMITH_MODEL" => nil, "OLLAMA_HOST" => nil}) do |temp_dir, home_dir|
      File.write(File.join(home_dir, "config.toml"), <<-TOML)
        [defaults]
        provider = "anthropic"

        [providers.anthropic]
        model = "claude-from-global"

        [providers.ollama]
        host = "http://global-ollama:11434"

        [http]
        connect_timeout = 5
        read_timeout = 60

        [approval]
        mode = "auto"
        allowlist = ["ls", "git status"]

        [context]
        max_tokens = 42000
        TOML

      project = make_project(temp_dir)
      config = Smith::Config.load(project)

      config.sources.size.should eq(1)
      config.provider.should eq("anthropic")
      config.model_for("anthropic").should eq("claude-from-global")
      config.ollama_host.should eq("http://global-ollama:11434")
      config.http.connect_timeout.should eq(5)
      config.http.read_timeout.should eq(60)
      config.approval.mode.should eq("auto")
      config.approval.allowlist.should eq(["ls", "git status"])
      config.context.max_tokens.should eq(42_000)
    end
  end

  it "lets the project config override the global config, key by key" do
    with_sandbox({"SMITH_PROVIDER" => nil, "SMITH_MODEL" => nil}) do |temp_dir, home_dir|
      File.write(File.join(home_dir, "config.toml"), <<-TOML)
        [defaults]
        provider = "anthropic"

        [providers.anthropic]
        model = "claude-from-global"

        [providers.openai]
        model = "gpt-from-global"
        TOML

      project = make_project(temp_dir, <<-TOML)
        [defaults]
        provider = "openai"

        [providers.anthropic]
        model = "claude-from-project"
        TOML

      config = Smith::Config.load(project)

      config.sources.size.should eq(2)
      config.provider.should eq("openai")
      config.model_for("anthropic").should eq("claude-from-project")
      # Untouched by the project file, so the global value survives the merge.
      config.model_for("openai").should eq("gpt-from-global")
    end
  end

  it "lets env vars override both config files" do
    with_sandbox({"SMITH_PROVIDER" => "ollama", "SMITH_MODEL" => "model-from-env"}) do |temp_dir, home_dir|
      File.write(File.join(home_dir, "config.toml"), <<-TOML)
        [defaults]
        provider = "anthropic"
        TOML

      project = make_project(temp_dir, <<-TOML)
        [defaults]
        provider = "openai"

        [providers.openai]
        model = "model-from-project"
        TOML

      config = Smith::Config.load(project)

      config.provider.should eq("ollama")
      config.model_for("openai").should eq("model-from-env")
    end
  end

  it "finds the project config from a subdirectory" do
    with_sandbox({"SMITH_PROVIDER" => nil, "SMITH_MODEL" => nil}) do |temp_dir, _home|
      project = make_project(temp_dir, <<-TOML)
        [defaults]
        provider = "ollama"
        TOML

      nested = File.join(project, "src", "deeply", "nested")
      FileUtils.mkdir_p(nested)

      Smith::Config.load(nested).provider.should eq("ollama")
    end
  end

  it "stops the upward walk at the git root" do
    with_sandbox({"SMITH_PROVIDER" => nil, "SMITH_MODEL" => nil}) do |temp_dir, _home|
      # Config sits above the git root, so it must not be picked up.
      FileUtils.mkdir_p(File.join(temp_dir, ".smith"))
      File.write(File.join(temp_dir, ".smith", "config.toml"), "[defaults]\nprovider = \"anthropic\"\n")

      project = make_project(temp_dir)

      Smith::Config.load(project).provider.should eq("openrouter")
    end
  end

  it "warns and keeps running when a config file is malformed" do
    with_sandbox({"SMITH_PROVIDER" => nil, "SMITH_MODEL" => nil}) do |temp_dir, home_dir|
      File.write(File.join(home_dir, "config.toml"), "[defaults\nthis is not valid toml")

      project = make_project(temp_dir, <<-TOML)
        [defaults]
        provider = "ollama"
        TOML

      config = Smith::Config.load(project)

      # The broken global file is skipped; the project file still applies.
      config.sources.size.should eq(1)
      config.provider.should eq("ollama")
    end
  end

  it "ignores unknown keys and wrongly typed values" do
    with_sandbox({"SMITH_PROVIDER" => nil, "SMITH_MODEL" => nil}) do |temp_dir, _home|
      project = make_project(temp_dir, <<-TOML)
        [defaults]
        provider = "ollama"
        totally_unknown_key = "ignored"

        [some_unknown_section]
        whatever = true

        [http]
        connect_timeout = "not a number"
        TOML

      config = Smith::Config.load(project)

      config.provider.should eq("ollama")
      config.http.connect_timeout.should eq(10)
    end
  end
end
