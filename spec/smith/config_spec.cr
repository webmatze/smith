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

describe "hook configuration" do
  it "has no hooks by default" do
    with_sandbox do |temp_dir, _home|
      Smith::Config.load(make_project(temp_dir)).hooks.should be_empty
    end
  end

  it "parses a hook table with its defaults" do
    with_sandbox do |temp_dir, _home|
      project = make_project(temp_dir, <<-TOML)
        [[hooks.pre_tool_use]]
        command = "check.sh"
        TOML

      hook = Smith::Config.load(project).hooks.first
      hook.event.should eq(Smith::Hooks::Event::PreToolUse)
      hook.command.should eq("check.sh")
      hook.matcher.should be_nil
      hook.timeout.should eq(60)
      hook.once?.should be_false
    end
  end

  it "parses matcher, timeout and once" do
    with_sandbox do |temp_dir, _home|
      project = make_project(temp_dir, <<-TOML)
        [[hooks.post_tool_use]]
        matcher = "write_file|edit_file"
        command = "crystal tool format"
        timeout = 30
        once = true
        TOML

      hook = Smith::Config.load(project).hooks.first
      hook.event.should eq(Smith::Hooks::Event::PostToolUse)
      hook.matcher.not_nil!.source.should eq("write_file|edit_file")
      hook.timeout.should eq(30)
      hook.once?.should be_true
    end
  end

  it "concatenates global and project hooks instead of replacing them" do
    with_sandbox do |temp_dir, home_dir|
      File.write(File.join(home_dir, "config.toml"), <<-TOML)
        [[hooks.pre_tool_use]]
        command = "global.sh"
        TOML

      project = make_project(temp_dir, <<-TOML)
        [[hooks.pre_tool_use]]
        command = "project.sh"
        TOML

      Smith::Config.load(project).hooks.map(&.command).should eq(["global.sh", "project.sh"])
    end
  end

  it "leaves other arrays overriding, as before" do
    with_sandbox do |temp_dir, home_dir|
      File.write(File.join(home_dir, "config.toml"), <<-TOML)
        [approval]
        allowlist = ["ls"]
        TOML

      project = make_project(temp_dir, <<-TOML)
        [approval]
        allowlist = ["git status"]
        TOML

      Smith::Config.load(project).approval.allowlist.should eq(["git status"])
    end
  end

  it "ignores unknown events and malformed entries rather than failing the run" do
    with_sandbox do |temp_dir, _home|
      project = make_project(temp_dir, <<-TOML)
        [[hooks.not_an_event]]
        command = "nope.sh"

        [[hooks.pre_tool_use]]
        matcher = "["
        command = "bad-regex.sh"

        [[hooks.pre_tool_use]]
        command = "good.sh"
        TOML

      Smith::Config.load(project).hooks.map(&.command).should eq(["good.sh"])
    end
  end

  it "reports whether the project config is the source of any hook" do
    with_sandbox do |temp_dir, home_dir|
      File.write(File.join(home_dir, "config.toml"), <<-TOML)
        [[hooks.stop]]
        command = "global.sh"
        TOML

      # Global-only hooks are the user's own doing and need no trust prompt.
      Smith::Config.load(make_project(temp_dir)).project_hooks_digest.should be_nil

      project = make_project(temp_dir, <<-TOML)
        [[hooks.stop]]
        command = "project.sh"
        TOML

      Smith::Config.load(project).project_hooks_digest.should_not be_nil
    end
  end

  it "changes the digest when the project hook section changes" do
    with_sandbox do |temp_dir, _home|
      before = Smith::Config.load(make_project(temp_dir, %([[hooks.stop]]\ncommand = "a.sh"))).project_hooks_digest
      after = Smith::Config.load(make_project(temp_dir, %([[hooks.stop]]\ncommand = "b.sh"))).project_hooks_digest

      before.should_not eq(after)
    end
  end
end

describe "anthropic caching setting" do
  it "is on by default" do
    with_sandbox do |temp_dir, _home|
      Smith::Config.load(make_project(temp_dir)).cache_for("anthropic").should be_true
    end
  end

  it "can be switched off per provider" do
    with_sandbox do |temp_dir, _home|
      project = make_project(temp_dir, <<-TOML)
        [providers.anthropic]
        cache = false
        TOML

      Smith::Config.load(project).cache_for("anthropic").should be_false
    end
  end
end

describe "permission rules" do
  it "parses allow, ask and deny" do
    with_sandbox do |temp_dir, _home|
      project = make_project(temp_dir, <<-TOML)
        [approval]
        allow = ["bash(git *)", "read_file(**)"]
        ask   = ["bash(git push *)"]
        deny  = ["bash(rm -rf *)"]
        TOML

      approval = Smith::Config.load(project).approval
      approval.allow.should eq(["bash(git *)", "read_file(**)"])
      approval.ask.should eq(["bash(git push *)"])
      approval.deny.should eq(["bash(rm -rf *)"])
    end
  end

  it "still understands the old bash-only allowlist" do
    with_sandbox do |temp_dir, _home|
      project = make_project(temp_dir, <<-TOML)
        [approval]
        allowlist = ["ls", "git status"]
        TOML

      approval = Smith::Config.load(project).approval
      # Kept verbatim for PromptApprover, and mirrored into the rule syntax.
      approval.allowlist.should eq(["ls", "git status"])
      approval.allow.should eq(["bash(ls)", "bash(git status)"])
    end
  end

  it "merges an old allowlist with new allow rules rather than dropping either" do
    with_sandbox do |temp_dir, _home|
      project = make_project(temp_dir, <<-TOML)
        [approval]
        allowlist = ["ls"]
        allow     = ["bash(git *)"]
        TOML

      Smith::Config.load(project).approval.allow.should eq(["bash(git *)", "bash(ls)"])
    end
  end

  it "has no rules at all by default" do
    with_sandbox do |temp_dir, _home|
      approval = Smith::Config.load(make_project(temp_dir)).approval

      approval.allow.should be_empty
      approval.ask.should be_empty
      approval.deny.should be_empty
    end
  end
end

describe "checkpoint settings" do
  it "is on by default with sane limits" do
    with_sandbox do |temp_dir, _home|
      settings = Smith::Config.load(make_project(temp_dir)).checkpoints

      settings.enabled?.should be_true
      settings.max_per_session.should eq(100)
      settings.retention_days.should eq(30)
    end
  end

  it "can be switched off and tuned" do
    with_sandbox do |temp_dir, _home|
      project = make_project(temp_dir, <<-TOML)
        [checkpoints]
        enabled = false
        max_per_session = 5
        retention_days = 1
        TOML

      settings = Smith::Config.load(project).checkpoints
      settings.enabled?.should be_false
      settings.max_per_session.should eq(5)
      settings.retention_days.should eq(1)
    end
  end
end

describe "bash settings" do
  it "defaults to a two-minute timeout and ten jobs" do
    with_sandbox do |temp_dir, _home|
      settings = Smith::Config.load(make_project(temp_dir)).bash

      settings.timeout.should eq(120)
      settings.max_background_jobs.should eq(10)
      settings.max_output_bytes.should eq(262_144)
    end
  end

  it "reads all three from the config" do
    with_sandbox do |temp_dir, _home|
      project = make_project(temp_dir, <<-TOML)
        [bash]
        timeout = 30
        max_background_jobs = 2
        max_output_bytes = 1024
        TOML

      settings = Smith::Config.load(project).bash
      settings.timeout.should eq(30)
      settings.max_background_jobs.should eq(2)
      settings.max_output_bytes.should eq(1024)
    end
  end
end

describe "mcp settings" do
  it "is on by default, with a sixty second call timeout" do
    with_sandbox do |temp_dir, _home|
      settings = Smith::Config.load(make_project(temp_dir)).mcp

      settings.enabled?.should be_true
      settings.timeout.should eq(60)
      settings.timeout_span.should eq(60.seconds)
    end
  end

  it "reads both from the config" do
    with_sandbox do |temp_dir, _home|
      project = make_project(temp_dir, <<-TOML)
        [mcp]
        enabled = false
        timeout = 15
        TOML

      settings = Smith::Config.load(project).mcp
      settings.enabled?.should be_false
      settings.timeout.should eq(15)
    end
  end

  it "lets MCP_TOOL_TIMEOUT win over the config" do
    with_sandbox({"MCP_TOOL_TIMEOUT" => "5"}) do |temp_dir, _home|
      project = make_project(temp_dir, "[mcp]\ntimeout = 15\n")
      Smith::Config.load(project).mcp.timeout.should eq(5)
    end
  end

  # A timeout of zero would mean "give up before asking", which is never what
  # anyone means by it.
  it "falls back to the default for a nonsensical timeout" do
    with_sandbox({"MCP_TOOL_TIMEOUT" => "0"}) do |temp_dir, _home|
      Smith::Config.load(make_project(temp_dir)).mcp.timeout.should eq(60)
    end
  end
end

describe "web settings" do
  it "blocks private addresses and disables search by default" do
    with_sandbox do |temp_dir, _home|
      settings = Smith::Config.load(make_project(temp_dir)).web

      settings.allow_private.should be_false
      settings.search_provider.should eq("none")
      settings.max_bytes.should eq(262_144)
    end
  end

  it "reads the web section" do
    with_sandbox do |temp_dir, _home|
      project = make_project(temp_dir, <<-TOML)
        [web]
        allow_private = true
        search_provider = "searxng"
        searxng_host = "http://localhost:9999"
        max_bytes = 1024
        TOML

      settings = Smith::Config.load(project).web
      settings.allow_private.should be_true
      settings.search_provider.should eq("searxng")
      settings.searxng_host.should eq("http://localhost:9999")
      settings.max_bytes.should eq(1024)
    end
  end
end

describe "pricing overrides" do
  it "has none by default, so the built-in table decides" do
    with_sandbox do |temp_dir, _home|
      Smith::Config.load(make_project(temp_dir)).pricing.should be_empty
    end
  end

  it "reads a rate per provider/model and accepts whole numbers" do
    with_sandbox do |temp_dir, _home|
      project = make_project(temp_dir, <<-TOML)
        [pricing."anthropic/claude-sonnet-5"]
        input = 2.0
        output = 10

        [pricing."openai/gpt-5.6-luna"]
        input = 1.25
        output = 5.0
        cache_read = 0.1
        TOML

      pricing = Smith::Config.load(project).pricing
      pricing["anthropic/claude-sonnet-5"].input.should eq(2.0)
      pricing["anthropic/claude-sonnet-5"].output.should eq(10.0)
      pricing["openai/gpt-5.6-luna"].cache_read.should eq(0.1)
      # Unstated cache rates follow Anthropic's published multipliers.
      pricing["openai/gpt-5.6-luna"].cache_write.should be_close(1.25 * 1.25, 0.0001)
    end
  end

  it "ignores an entry that does not state both base rates" do
    with_sandbox do |temp_dir, _home|
      project = make_project(temp_dir, <<-TOML)
        [pricing."anthropic/claude-sonnet-5"]
        input = 2.0
        TOML

      # Half a rate would price completions at zero, which reads as cheap
      # rather than as unknown.
      Smith::Config.load(project).pricing.should be_empty
    end
  end
end

describe "mention settings" do
  it "defaults to project-local mentions with Claude Code's line limit" do
    with_sandbox do |temp_dir, _home|
      mentions = Smith::Config.load(make_project(temp_dir)).mentions

      mentions.max_lines.should eq(2000)
      mentions.max_total_bytes.should eq(262144)
      mentions.allow_outside?.should be_false
    end
  end

  it "reads the section" do
    with_sandbox do |temp_dir, _home|
      project = make_project(temp_dir, <<-TOML)
        [mentions]
        max_lines = 50
        max_total_bytes = 1024
        allow_outside = true
        TOML

      mentions = Smith::Config.load(project).mentions
      mentions.max_lines.should eq(50)
      mentions.max_total_bytes.should eq(1024)
      mentions.allow_outside?.should be_true
    end
  end
end

describe "thinking settings" do
  it "is off by default, and leaves the legacy budget unset" do
    with_sandbox do |temp_dir, _home|
      config = Smith::Config.load(make_project(temp_dir))

      config.thinking?.should be_false
      config.thinking_effort.should eq("medium")
      # Setting it would make current Anthropic models reject every request.
      config.thinking_budget.should be_nil
      config.reasoning_effort.should eq("none")
    end
  end

  it "reads all four" do
    with_sandbox do |temp_dir, _home|
      project = make_project(temp_dir, <<-TOML)
        [defaults]
        thinking = true

        [providers.anthropic]
        thinking_effort = "high"
        thinking_budget = 8000

        [providers.openai]
        reasoning_effort = "high"
        TOML

      config = Smith::Config.load(project)
      config.thinking?.should be_true
      config.thinking_effort.should eq("high")
      config.thinking_budget.should eq(8000)
      config.reasoning_effort.should eq("high")
    end
  end
end
