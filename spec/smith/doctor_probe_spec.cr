require "../spec_helper"
require "file_utils"
require "http/server"
require "../../src/smith/doctor"

# The probes `smith doctor` really runs, driven for real rather than stubbed.
#
# The rest of the doctor specs inject every outward probe, which is what keeps
# them fast and independent of the machine — and is also why they could not
# have caught a secret leaking out of a *child process*. These make the round
# trip: a real subprocess, a real socket, and assertions on what came back.
private def in_home(&)
  root = File.join(Dir.tempdir, "smith_doctor_probe_#{Random::Secure.hex(4)}")
  home = File.join(root, "smith-home")
  workdir = File.join(root, "project")
  FileUtils.mkdir_p(home)
  FileUtils.mkdir_p(workdir)
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

private def write_server(dir : String, name : String, body : String) : String
  path = File.join(dir, name)
  File.write(path, body)
  File.chmod(path, 0o755)
  path
end

private def mcp_json(home : String, entries : String) : Nil
  File.write(File.join(home, "mcp.json"), %({"mcpServers": #{entries}}))
end

private def rendered(probe : Smith::Doctor::McpProbe) : String
  io = IO::Memory.new
  Smith::Doctor.render(Smith::Doctor::Report.new([Smith::Doctor.mcp_check(probe)]), io)
  io.to_s
end

describe "Smith::Doctor.probe_mcp" do
  it "keeps what a server writes to its own stderr out of the report" do
    in_home do |home, workdir|
      # A stdio server inherits smith's environment, so anything it prints is
      # a channel out of it. The probe has to be built from what smith knows,
      # never from what the child chose to say.
      secret = "sk-doctor-probe-#{Random::Secure.hex(6)}"
      previous = ENV["OPENROUTER_API_KEY"]?
      ENV["OPENROUTER_API_KEY"] = secret

      begin
        server = write_server(home, "leaky.sh", <<-SH)
          #!/bin/sh
          env | grep -o 'OPENROUTER_API_KEY=.*' >&2
          exit 1
          SH
        mcp_json(home, %({"leaky": {"command": "#{server}"}}))

        probe = Smith::Doctor.probe_mcp(Smith::Config.load(workdir), workdir)

        probe.servers.size.should eq(1)
        probe.servers.first.ok?.should be_false
        rendered(probe).should_not contain(secret)
      ensure
        if previous
          ENV["OPENROUTER_API_KEY"] = previous
        else
          ENV.delete("OPENROUTER_API_KEY")
        end
      end
    end
  end

  it "summarises an argument list instead of repeating it" do
    in_home do |home, workdir|
      # `--api-key X` is an ordinary way to configure a server, so the values
      # never appear — only how many there were.
      mcp_json(home, %({"argued": {"command": "/nonexistent-smith-doctor", "args": ["--api-key", "ARGTOKEN"]}}))

      probe = Smith::Doctor.probe_mcp(Smith::Config.load(workdir), workdir)
      output = rendered(probe)

      output.should_not contain("ARGTOKEN")
      output.should contain("2 arguments")
    end
  end

  it "cuts a url back to scheme, host and port everywhere it appears" do
    in_home do |home, workdir|
      mcp_json(home, %({"remote": {"url": "https://user:PASSWD@127.0.0.1:1/p/PATHSECRET?t=QUERYSECRET#FRAGSECRET"}}))

      probe = Smith::Doctor.probe_mcp(Smith::Config.load(workdir), workdir)
      output = rendered(probe)

      probe.servers.first.target.should eq("https://127.0.0.1:1")
      %w[PASSWD PATHSECRET QUERYSECRET FRAGSECRET].each { |secret| output.should_not contain(secret) }
    end
  end

  it "sanitises the warning a rejected url produces" do
    in_home do |home, workdir|
      mcp_json(home, %({"bad": {"type": "http", "url": "ftp://host/x?token=WARNSECRET"}}))

      rendered(Smith::Doctor.probe_mcp(Smith::Config.load(workdir), workdir))
        .should_not contain("WARNSECRET")
    end
  end

  it "keeps an http server's error body out of the report" do
    in_home do |home, workdir|
      # A gateway that echoes the Authorization header it was sent back into
      # its error page. Not exotic — a proxy error page, a debug endpoint, or
      # simply a server nobody here controls. The status is smith's
      # diagnosis; the body is the server's own text.
      secret = "sk-gateway-#{Random::Secure.hex(6)}"
      previous = ENV["OPENROUTER_API_KEY"]?
      ENV["OPENROUTER_API_KEY"] = secret

      server = HTTP::Server.new do |context|
        context.response.status = HTTP::Status::INTERNAL_SERVER_ERROR
        context.response.print "upstream rejected; sent #{context.request.headers["Authorization"]?}"
      end
      address = server.bind_unused_port("127.0.0.1")
      spawn { server.listen }

      begin
        mcp_json(home, <<-JSON)
          {"gateway": {
            "url": "http://127.0.0.1:#{address.port}/mcp",
            "headers": {"Authorization": "Bearer ${OPENROUTER_API_KEY}"}
          }}
          JSON

        probe = Smith::Doctor.probe_mcp(Smith::Config.load(workdir), workdir)
        output = rendered(probe)

        probe.servers.first.ok?.should be_false
        # The status still has to reach the report — it is the diagnosis.
        output.should contain("HTTP 500")
        output.should_not contain(secret)
      ensure
        server.close
        if previous
          ENV["OPENROUTER_API_KEY"] = previous
        else
          ENV.delete("OPENROUTER_API_KEY")
        end
      end
    end
  end

  it "leaves no child process behind when a server has to be killed" do
    in_home do |home, workdir|
      pid_file = File.join(home, "server.pid")
      # Ignores TERM and outlives stdin: only SIGKILL ends it, which is what
      # the zero shutdown grace is for. A probe that leaked processes would
      # be worse than no probe at all.
      server = write_server(home, "stubborn.sh", <<-SH)
          #!/bin/bash
          trap '' TERM INT HUP PIPE
          printf '%s' "$$" > "#{pid_file}"
          while :; do IFS= read -r line || sleep 3600; done
          SH
      mcp_json(home, %({"stubborn": {"command": "#{server}"}}))

      Smith::Doctor.probe_mcp(Smith::Config.load(workdir), workdir)

      pid = File.read(pid_file).strip.to_i
      # SIGKILL is delivered by the time `kill` returns, but the reaping is
      # the parent's next scheduling turn.
      20.times do
        break unless Process.exists?(pid)
        sleep 50.milliseconds
      end

      Process.exists?(pid).should be_false
    end
  end

  it "names every configured server when the handshakes run out of time" do
    in_home do |home, workdir|
      # Answers initialize, then pages tools/list forever: nothing in the MCP
      # client bounds that, so only the probe's own cap ends it.
      server = write_server(home, "endless.sh", <<-SH)
          #!/bin/bash
          page=0
          while IFS= read -r line; do
            id=${line#*\\"id\\":}
            id=${id%%,*}
            case "$line" in
              *'"method":"initialize"'*)
                printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"e","version":"1"}}}\\n' "$id" ;;
              *'"method":"tools/list"'*)
                page=$((page + 1))
                printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"t","description":"x","inputSchema":{"type":"object"}}],"nextCursor":"p%s"}}\\n' "$id" "$page" ;;
            esac
          done
          SH
      mcp_json(home, %({"endless": {"command": "#{server}"}}))

      started = Time.instant
      probe = Smith::Doctor.probe_mcp(Smith::Config.load(workdir), workdir)
      elapsed = Time.instant - started

      elapsed.should be < Smith::Doctor::MCP_DEADLINE + 2.seconds
      probe.servers.map(&.name).should eq(["endless"])
      probe.servers.first.error.to_s.should contain("no answer within")
      # The verdict matters more than the wording: a probe that could not
      # finish must not read as a healthy one.
      Smith::Doctor.mcp_check(probe).status.should eq(Smith::Doctor::Status::Fail)
    end
  end
end

describe "Smith::Doctor.plan_mcp" do
  it "reads the configured servers without starting any of them" do
    in_home do |home, workdir|
      mcp_json(home, %({"a": {"command": "/bin/true"}, "b": {"url": "http://127.0.0.1:1/mcp"}}))

      plan = Smith::Doctor.plan_mcp(Smith::Config.load(workdir), workdir)

      plan.sources.should eq([File.join(home, "mcp.json")])
      plan.specs.map(&.name).sort.should eq(["a", "b"])
      plan.probes?.should be_true

      # The fallback the gather uses when the clock runs out: every server
      # still named, and the whole check a failure.
      unprobed = plan.unprobed("ran out of time")
      unprobed.servers.map(&.name).sort.should eq(["a", "b"])
      Smith::Doctor.mcp_check(unprobed).status.should eq(Smith::Doctor::Status::Fail)
    end
  end
end

describe "Smith::Doctor.probe_ollama" do
  it "reads the models a host reports" do
    server = HTTP::Server.new do |context|
      context.response.content_type = "application/json"
      context.response.print %({"models": [{"name": "gemma:latest"}, {"name": "qwen:7b"}]})
    end
    address = server.bind_unused_port("127.0.0.1")
    spawn { server.listen }

    begin
      probe = Smith::Doctor.probe_ollama("http://127.0.0.1:#{address.port}")

      probe.reachable?.should be_true
      probe.models.should eq(["gemma:latest", "qwen:7b"])
    ensure
      server.close
    end
  end

  it "asks the host for /api/tags rather than gluing a string to it" do
    seen = [] of String
    server = HTTP::Server.new do |context|
      seen << context.request.resource
      context.response.print %({"models": []})
    end
    address = server.bind_unused_port("127.0.0.1")
    spawn { server.listen }

    begin
      # A host with a query would otherwise put it in the middle of the path,
      # and from there into the message when the probe fails.
      Smith::Doctor.probe_ollama("http://127.0.0.1:#{address.port}/?apikey=OLLAMASECRET")

      seen.should eq(["/api/tags"])
    ensure
      server.close
    end
  end

  it "keeps a host's credentials out of the failure it reports" do
    probe = Smith::Doctor.probe_ollama("http://user:OLLAMAPASS@127.0.0.1:1/?apikey=OLLAMASECRET")

    probe.reachable?.should be_false
    probe.error.to_s.should_not contain("OLLAMAPASS")
    probe.error.to_s.should_not contain("OLLAMASECRET")
  end

  it "answers rather than raising when the host is not there" do
    probe = Smith::Doctor.probe_ollama("http://127.0.0.1:1")

    probe.reachable?.should be_false
    probe.models.should be_empty
  end

  it "treats a body it cannot read as no models rather than an error" do
    server = HTTP::Server.new { |context| context.response.print "not json at all" }
    address = server.bind_unused_port("127.0.0.1")
    spawn { server.listen }

    begin
      probe = Smith::Doctor.probe_ollama("http://127.0.0.1:#{address.port}")

      probe.reachable?.should be_true
      probe.models.should be_empty
    ensure
      server.close
    end
  end

  it "reports a host that answers with an error status" do
    server = HTTP::Server.new { |context| context.response.status = HTTP::Status::INTERNAL_SERVER_ERROR }
    address = server.bind_unused_port("127.0.0.1")
    spawn { server.listen }

    begin
      Smith::Doctor.probe_ollama("http://127.0.0.1:#{address.port}").error.to_s.should contain("HTTP 500")
    ensure
      server.close
    end
  end
end

describe "Smith::Doctor.catalog_notes" do
  it "collects what both catalogs could not load" do
    in_home do |home, workdir|
      FileUtils.mkdir_p(File.join(home, "skills", "broken"))
      FileUtils.mkdir_p(File.join(home, "agents"))
      # A frontmatter block that opens and never closes, and an agent with no
      # description: both load anyway, degraded, which is exactly the kind of
      # thing a count of two hides.
      File.write(File.join(home, "skills", "broken", "SKILL.md"), "---\nname: halfopen\n")
      File.write(File.join(home, "agents", "bare.md"), "---\nname: bare\n---\n\nNo description.\n")

      notes = Smith::Doctor.catalog_notes(
        Smith::Skills::Catalog.discover(workdir),
        Smith::Agents::Catalog.discover(workdir, warn_io: IO::Memory.new)
      )

      notes.size.should eq(2)
      # Named by its directory, because the frontmatter that would have given
      # it a name is the thing that did not read.
      notes.any?(&.includes?("Skill 'broken'")).should be_true
      notes.any?(&.includes?("Agent 'bare'")).should be_true
      Smith::Doctor.environment_check(home, true, nil, [] of String, 1, 1, notes).status
        .should eq(Smith::Doctor::Status::Warn)
    end
  end

  it "finds nothing to say about catalogs that loaded cleanly" do
    in_home do |_home, workdir|
      Smith::Doctor.catalog_notes(
        Smith::Skills::Catalog.discover(workdir),
        Smith::Agents::Catalog.discover(workdir, warn_io: IO::Memory.new)
      ).should be_empty
    end
  end

  it "still has its warnings after the catalog has reported them" do
    in_home do |home, workdir|
      FileUtils.mkdir_p(File.join(home, "agents"))
      File.write(File.join(home, "agents", "bare.md"), "---\nname: bare\n---\n\nNo description.\n")

      # `discover` reports to stderr in the CLI constructor, before the CLI
      # knows which command was asked for. Doctor reads them afterwards, and
      # would otherwise have to walk the same directories a second time.
      catalog = Smith::Agents::Catalog.discover(workdir, warn_io: IO::Memory.new)

      catalog.warnings.size.should eq(1)
      catalog.warnings.first.should contain("Agent 'bare'")
    end
  end
end

describe Smith::Doctor::Runner do
  it "runs its own probes end to end when none are injected" do
    in_home do |_home, workdir|
      previous = ENV["OLLAMA_HOST"]?
      # A refused port rather than a real Ollama: this has to exercise the
      # default probes without depending on what the developer is running.
      ENV["OLLAMA_HOST"] = "http://127.0.0.1:1"

      begin
        report = Smith::Doctor::Runner.new(
          config: Smith::Config.load(workdir),
          provider: "openrouter",
          model: "some/model",
          mode: "normal",
          skills: 0,
          agents: 0,
          start_dir: workdir,
          keys: {"OPENROUTER_API_KEY" => true}
        ).run

        report.checks.size.should eq(7)

        ollama = report.checks.find! { |check| check.title == "Ollama" }
        ollama.details.any?(&.includes?("not reachable")).should be_true

        # The real sandbox probe ran: shape only, since the answer differs
        # per platform.
        sandbox = report.checks.find! { |check| check.title == "Sandbox" }
        sandbox.details.any?(&.starts_with?("trial run: ")).should be_true
      ensure
        if previous
          ENV["OLLAMA_HOST"] = previous
        else
          ENV.delete("OLLAMA_HOST")
        end
      end
    end
  end
end
