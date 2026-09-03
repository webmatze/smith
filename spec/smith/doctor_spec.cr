require "../spec_helper"
require "file_utils"
require "../../src/smith/doctor"

private def keys(**overrides) : Hash(String, Bool)
  present = Hash(String, Bool).new
  (Smith::Doctor::PROVIDER_KEYS.values + Smith::Doctor::SEARCH_KEYS.values).each { |var| present[var] = false }
  overrides.each { |name, value| present[name.to_s] = value }
  present
end

private def check_for(report : Smith::Doctor::Report, title : String) : Smith::Doctor::Check
  report.checks.find { |check| check.title == title }.not_nil!
end

private def render(report : Smith::Doctor::Report) : String
  io = IO::Memory.new
  Smith::Doctor.render(report, io)
  io.to_s
end

# Everything the doctor reads out of a home directory — config, mcp.json,
# global instructions — moves with SMITH_HOME, and a spec that skipped this
# would report on the developer's own machine instead of on its fixture.
private def in_home(&)
  root = File.join(Dir.tempdir, "smith_doctor_#{Random::Secure.hex(4)}")
  home = File.join(root, "smith-home")
  workdir = File.join(root, "project")
  FileUtils.mkdir_p(home)
  FileUtils.mkdir_p(workdir)
  # A git root, so the upward walks stop here rather than at the real repo.
  File.write(File.join(workdir, ".git"), "gitdir: #{root}/.git\n")

  previous = ENV["SMITH_HOME"]?
  ENV["SMITH_HOME"] = home

  begin
    yield home, workdir
  ensure
    if previous
      ENV["SMITH_HOME"] = previous
    else
      ENV.delete("SMITH_HOME")
    end
    FileUtils.rm_rf(root)
  end
end

private def runner(workdir : String, **overrides) : Smith::Doctor::Runner
  defaults = {
    config:        Smith::Config.load(workdir),
    provider:      "openrouter",
    model:         "some/model",
    mode:          "normal",
    skills:        0,
    agents:        0,
    start_dir:     workdir,
    keys:          keys(OPENROUTER_API_KEY: true),
    ollama_probe:  ->(_host : String) { Smith::Doctor::OllamaProbe.new(error: "stubbed") },
    mcp_probe:     -> { Smith::Doctor::McpProbe.new },
    sandbox_probe: -> { Smith::Sandbox::Probe.new(Smith::Sandbox::Availability::Usable, "stubbed") },
  }

  Smith::Doctor::Runner.new(**defaults.merge(overrides))
end

describe Smith::Doctor::Report do
  it "fails the exit code on a fail and not on a warn" do
    warned = Smith::Doctor::Report.new([
      Smith::Doctor::Check.new("A", Smith::Doctor::Status::Ok),
      Smith::Doctor::Check.new("B", Smith::Doctor::Status::Warn),
    ])
    warned.failed?.should be_false
    warned.exit_code.should eq(0)

    failed = Smith::Doctor::Report.new([
      Smith::Doctor::Check.new("A", Smith::Doctor::Status::Warn),
      Smith::Doctor::Check.new("B", Smith::Doctor::Status::Fail),
    ])
    failed.failed?.should be_true
    failed.exit_code.should eq(1)
  end

  it "counts what it found" do
    report = Smith::Doctor::Report.new([
      Smith::Doctor::Check.new("A", Smith::Doctor::Status::Ok),
      Smith::Doctor::Check.new("B", Smith::Doctor::Status::Ok),
      Smith::Doctor::Check.new("C", Smith::Doctor::Status::Fail),
    ])

    report.count(Smith::Doctor::Status::Ok).should eq(2)
    report.count(Smith::Doctor::Status::Warn).should eq(0)
    report.count(Smith::Doctor::Status::Fail).should eq(1)
  end
end

describe ".provider_check" do
  it "names every provider as set or missing" do
    check = Smith::Doctor.provider_check(keys(OPENROUTER_API_KEY: true), "openrouter")

    check.status.should eq(Smith::Doctor::Status::Ok)
    check.details.should contain("openrouter (in use): OPENROUTER_API_KEY set")
    check.details.should contain("anthropic: ANTHROPIC_API_KEY missing")
    check.details.should contain("openai: OPENAI_API_KEY missing")
    check.details.should contain("ollama: no API key needed")
  end

  it "fails only when the provider actually in use has no key" do
    Smith::Doctor.provider_check(keys, "anthropic").status.should eq(Smith::Doctor::Status::Fail)
    # Another provider's key being absent is a fact, not a failure.
    Smith::Doctor.provider_check(keys(ANTHROPIC_API_KEY: true), "anthropic").status
      .should eq(Smith::Doctor::Status::Ok)
  end

  it "passes for ollama, which needs no key at all" do
    Smith::Doctor.provider_check(keys, "ollama").status.should eq(Smith::Doctor::Status::Ok)
  end

  it "fails on a provider smith cannot build" do
    check = Smith::Doctor.provider_check(keys(OPENROUTER_API_KEY: true), "gemini")

    check.status.should eq(Smith::Doctor::Status::Fail)
    check.details.last.should contain("is not a provider smith knows")
  end
end

describe ".config_check" do
  it "reports the loaded files and the effective defaults" do
    check = Smith::Doctor.config_check(["/a/config.toml"], ["/a/config.toml"], "anthropic", "claude-x", "plan")

    check.status.should eq(Smith::Doctor::Status::Ok)
    check.details.should contain("loaded: /a/config.toml")
    check.details.should contain("[defaults] provider: anthropic")
    check.details.should contain("[defaults] model: claude-x")
    check.details.should contain("[defaults] mode: plan")
  end

  it "says so when nothing was loaded" do
    check = Smith::Doctor.config_check([] of String, [] of String, "openrouter", "m", "normal")

    check.status.should eq(Smith::Doctor::Status::Ok)
    check.details.first.should contain("no config.toml loaded")
  end

  it "warns about a config file that exists but was not read" do
    check = Smith::Doctor.config_check([] of String, ["/a/config.toml"], "openrouter", "m", "normal")

    check.status.should eq(Smith::Doctor::Status::Warn)
    check.details.last.should contain("/a/config.toml")
  end
end

describe ".ollama_check" do
  it "lists the models when the host answers" do
    probe = Smith::Doctor::OllamaProbe.new(models: ["gemma:latest", "qwen:7b"])
    check = Smith::Doctor.ollama_check("http://localhost:11434", probe, active: true, configured: true)

    check.status.should eq(Smith::Doctor::Status::Ok)
    check.details.last.should contain("2 models: gemma:latest, qwen:7b")
  end

  it "fails when the provider in use is unreachable" do
    probe = Smith::Doctor::OllamaProbe.new(error: "not reachable: connection refused")
    Smith::Doctor.ollama_check("http://localhost:11434", probe, active: true, configured: true).status
      .should eq(Smith::Doctor::Status::Fail)
  end

  it "stays quiet about an Ollama nobody asked for" do
    probe = Smith::Doctor::OllamaProbe.new(error: "not reachable: connection refused")

    # Configured but unused is worth a warning; never configured and unused is
    # not a finding at all — otherwise every user of another provider gets a
    # permanent warning about software they do not run.
    Smith::Doctor.ollama_check("http://elsewhere:11434", probe, active: false, configured: true).status
      .should eq(Smith::Doctor::Status::Warn)
    Smith::Doctor.ollama_check("http://localhost:11434", probe, active: false, configured: false).status
      .should eq(Smith::Doctor::Status::Ok)
  end

  it "flags a reachable host with nothing pulled" do
    probe = Smith::Doctor::OllamaProbe.new
    check = Smith::Doctor.ollama_check("http://localhost:11434", probe, active: true, configured: true)

    check.status.should eq(Smith::Doctor::Status::Fail)
    check.details.last.should contain("no models are pulled")
  end
end

describe ".mcp_check" do
  it "passes when there is nothing configured" do
    check = Smith::Doctor.mcp_check(Smith::Doctor::McpProbe.new)

    check.status.should eq(Smith::Doctor::Status::Ok)
    check.details.first.should contain("no mcp.json found")
  end

  it "reports a server that answered the handshake" do
    probe = Smith::Doctor::McpProbe.new(
      sources: ["/home/.smith/mcp.json"],
      servers: [Smith::Doctor::McpServerProbe.new("fs", "stdio", "npx server-filesystem", 12)]
    )
    check = Smith::Doctor.mcp_check(probe)

    check.status.should eq(Smith::Doctor::Status::Ok)
    check.details.should contain("config: /home/.smith/mcp.json")
    check.details.last.should contain("fs (stdio) ✓ 12 tools")
  end

  it "fails on a server that did not start" do
    probe = Smith::Doctor::McpProbe.new(
      servers: [Smith::Doctor::McpServerProbe.new("broken", "stdio", "nope", error: "command not found: nope")]
    )
    check = Smith::Doctor.mcp_check(probe)

    check.status.should eq(Smith::Doctor::Status::Fail)
    check.details.last.should contain("command not found")
  end

  it "warns on a config smith could not fully read" do
    probe = Smith::Doctor::McpProbe.new(warnings: ["⚠️  Skipping MCP server 'x': no \"command\"."])

    Smith::Doctor.mcp_check(probe).status.should eq(Smith::Doctor::Status::Warn)
  end

  it "says nothing more when MCP is switched off" do
    check = Smith::Doctor.mcp_check(Smith::Doctor::McpProbe.new(enabled: false))

    check.status.should eq(Smith::Doctor::Status::Ok)
    check.details.should eq(["switched off ([mcp] enabled = false)"])
  end
end

describe ".web_search_check" do
  it "passes when searching is off" do
    Smith::Doctor.web_search_check("none", keys, "http://localhost:8888").status
      .should eq(Smith::Doctor::Status::Ok)
  end

  it "fails a backend whose key is missing" do
    check = Smith::Doctor.web_search_check("brave", keys, "http://localhost:8888")

    check.status.should eq(Smith::Doctor::Status::Fail)
    check.details.should contain("BRAVE_API_KEY: missing")
  end

  it "passes a backend whose key is set" do
    check = Smith::Doctor.web_search_check("tavily", keys(TAVILY_API_KEY: true), "http://localhost:8888")

    check.status.should eq(Smith::Doctor::Status::Ok)
    check.details.should contain("TAVILY_API_KEY: set")
  end

  it "passes searxng, which needs no key" do
    check = Smith::Doctor.web_search_check("searxng", keys, "http://search.local")

    check.status.should eq(Smith::Doctor::Status::Ok)
    check.details.should contain("host: http://search.local")
  end

  it "fails a backend name smith does not know" do
    Smith::Doctor.web_search_check("kagi", keys, "http://localhost:8888").status
      .should eq(Smith::Doctor::Status::Fail)
  end
end

describe ".sandbox_check" do
  usable = Smith::Sandbox::Probe.new(Smith::Sandbox::Availability::Usable, "a trial run succeeded")
  blocked = Smith::Sandbox::Probe.new(Smith::Sandbox::Availability::Blocked, "refused: Operation not permitted")

  it "passes when the sandbox is off, whatever the trial run said" do
    check = Smith::Doctor.sandbox_check(false, false, "off", blocked)

    check.status.should eq(Smith::Doctor::Status::Ok)
    check.details.should contain("trial run: refused: Operation not permitted")
  end

  it "passes when the sandbox is on and the trial run worked" do
    Smith::Doctor.sandbox_check(true, false, "sandbox-exec", usable).status
      .should eq(Smith::Doctor::Status::Ok)
  end

  it "fails when the sandbox was asked for and is not in force" do
    check = Smith::Doctor.sandbox_check(true, false, "off", blocked)

    check.status.should eq(Smith::Doctor::Status::Fail)
    check.details.last.should contain("bash runs with your full rights")

    required = Smith::Doctor.sandbox_check(true, true, "off", blocked)
    required.status.should eq(Smith::Doctor::Status::Fail)
    required.details.last.should contain("refuse to run")
  end
end

describe ".environment_check" do
  it "names the version, the home, the instructions and the catalogs" do
    check = Smith::Doctor.environment_check(
      "/tmp/home", true, "/tmp/home/AGENTS.md", ["/proj/SMITH.md"], 3, 2
    )

    check.status.should eq(Smith::Doctor::Status::Ok)
    check.details.should contain("version: smith #{Smith::VERSION}")
    check.details.should contain("home: /tmp/home (SMITH_HOME override)")
    check.details.should contain("global instructions: /tmp/home/AGENTS.md")
    check.details.should contain("project instructions: /proj/SMITH.md")
    check.details.should contain("skills: 3")
    check.details.should contain("agents: 2")
  end

  it "says when there are no instructions at all" do
    check = Smith::Doctor.environment_check("/tmp/home", false, nil, [] of String, 0, 0)

    check.details.should contain("global instructions: none in /tmp/home")
    check.details.any?(&.starts_with?("project instructions: none")).should be_true
  end
end

describe ".render" do
  it "prints one block per check and a tally" do
    report = Smith::Doctor::Report.new([
      Smith::Doctor::Check.new("Provider", Smith::Doctor::Status::Fail, ["openrouter: missing"]),
      Smith::Doctor::Check.new("Config", Smith::Doctor::Status::Warn, ["nothing loaded"]),
    ])
    output = render(report)

    output.should contain("❌ Provider — fail")
    output.should contain("   openrouter: missing")
    output.should contain("⚠️  Config — warn")
    output.should contain("0 ok, 1 warn, 1 fail")
    output.should contain("A warning does not change the exit code")
  end
end

describe Smith::Doctor::Runner do
  it "produces the seven checks without touching the network" do
    in_home do |_home, workdir|
      report = runner(workdir).run

      report.checks.map(&.title).should eq(
        ["Provider", "Config", "Ollama", "MCP", "web_search", "Sandbox", "Environment"]
      )
      report.exit_code.should eq(0)
    end
  end

  it "reads the config, the instructions and the mcp switch out of SMITH_HOME" do
    in_home do |home, workdir|
      File.write(File.join(home, "config.toml"), <<-TOML)
        [defaults]
        provider = "anthropic"

        [mcp]
        enabled = false
        TOML
      File.write(File.join(home, "AGENTS.md"), "global instructions")
      File.write(File.join(workdir, "SMITH.md"), "project instructions")

      report = runner(
        workdir,
        provider: "anthropic",
        model: "claude-x",
        keys: keys(ANTHROPIC_API_KEY: true),
        mcp_probe: -> { Smith::Doctor.probe_mcp(Smith::Config.load(workdir), workdir) }
      ).run

      check_for(report, "Config").details.should contain("loaded: #{File.join(home, "config.toml")}")
      check_for(report, "Config").details.should contain("[defaults] provider: anthropic")
      check_for(report, "MCP").details.should eq(["switched off ([mcp] enabled = false)"])

      environment = check_for(report, "Environment").details
      environment.should contain("global instructions: #{File.join(home, "AGENTS.md")}")
      environment.should contain("project instructions: #{File.join(workdir, "SMITH.md")}")
      environment.should contain("home: #{home} (SMITH_HOME override)")
    end
  end

  it "exits non-zero when a probe reports a broken server" do
    in_home do |_home, workdir|
      broken = Smith::Doctor::McpProbe.new(
        servers: [Smith::Doctor::McpServerProbe.new("x", "stdio", "nope", error: "command not found")]
      )
      report = runner(workdir, mcp_probe: -> { broken }).run

      report.exit_code.should eq(1)
      check_for(report, "MCP").status.should eq(Smith::Doctor::Status::Fail)
    end
  end

  it "survives a probe that raises" do
    in_home do |_home, workdir|
      report = runner(
        workdir,
        ollama_probe: ->(_host : String) { raise "boom"; Smith::Doctor::OllamaProbe.new }
      ).run

      # Unreachable and unconfigured stays a note rather than a finding; what
      # matters is that one broken probe does not take the report with it.
      report.checks.size.should eq(7)
      check_for(report, "Ollama").details.last.should contain("probe failed")
    end
  end

  it "never prints a key value" do
    in_home do |_home, workdir|
      secret = "sk-doctor-must-never-print-#{Random::Secure.hex(4)}"
      previous = ENV["OPENROUTER_API_KEY"]?
      ENV["OPENROUTER_API_KEY"] = secret

      begin
        # env_keys is the real reader, so this covers the path `smith doctor`
        # actually takes rather than a hand-built hash.
        output = render(runner(workdir, keys: Smith::Doctor.env_keys).run)

        output.should contain("OPENROUTER_API_KEY set")
        output.should_not contain(secret)
        output.should_not contain(secret[0, 8])
      ensure
        if previous
          ENV["OPENROUTER_API_KEY"] = previous
        else
          ENV.delete("OPENROUTER_API_KEY")
        end
      end
    end
  end
end

describe ".probe_mcp" do
  it "reports a server that does not exist without waiting for a timeout" do
    in_home do |home, workdir|
      File.write(File.join(home, "mcp.json"), %({"mcpServers": {"ghost": {"command": "/nonexistent-smith-doctor"}}}))

      started = Time.instant
      probe = Smith::Doctor.probe_mcp(Smith::Config.load(workdir), workdir)
      elapsed = Time.instant - started

      probe.sources.should eq([File.join(home, "mcp.json")])
      probe.servers.size.should eq(1)
      probe.servers.first.ok?.should be_false
      probe.servers.first.kind.should eq("stdio")
      elapsed.should be < Smith::Doctor::MCP_DEADLINE
    end
  end

  it "bounds a server that starts and never answers the handshake" do
    in_home do |home, workdir|
      # `sleep` starts fine and never speaks MCP — the handshake timeout is
      # the only thing that ends this, which is exactly what is under test.
      File.write(
        File.join(home, "mcp.json"),
        %({"mcpServers": {"mute": {"command": "/bin/sleep", "args": ["60"]}}})
      )

      started = Time.instant
      probe = Smith::Doctor.probe_mcp(Smith::Config.load(workdir), workdir)
      elapsed = Time.instant - started

      probe.servers.first.ok?.should be_false
      elapsed.should be < Smith::Doctor::MCP_DEADLINE + 2.seconds
    end
  end

  it "keeps a url's query string out of the report" do
    in_home do |home, workdir|
      # Port 1 on localhost refuses at once: what is under test is what ends up
      # printed, and a blackhole address would only make the suite slower.
      File.write(
        File.join(home, "mcp.json"),
        %({"mcpServers": {"remote": {"url": "http://127.0.0.1:1/mcp?token=super-secret"}}})
      )

      probe = Smith::Doctor.probe_mcp(Smith::Config.load(workdir), workdir)

      probe.servers.first.kind.should eq("http")
      probe.servers.first.target.should eq("http://127.0.0.1:1/mcp")
      probe.servers.first.target.should_not contain("super-secret")

      # The failure message quotes the url it tried, so it has to be trimmed
      # too — a token in a query string is a token wherever it is printed.
      probe.servers.first.error.to_s.should_not contain("super-secret")
      Smith::Doctor.mcp_check(probe).details.join("\n").should_not contain("super-secret")
    end
  end
end
