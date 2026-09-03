require "../spec_helper"
require "file_utils"
require "../../src/smith/sandbox"

private def policy(**options) : Smith::Sandbox::Policy
  Smith::Sandbox::Policy.new(**options.merge(enabled: true))
end

private def macos(workdir : String = "/project", **options) : Smith::Sandbox::MacOS
  Smith::Sandbox::MacOS.new(policy(**options), workdir)
end

# The specs that run a real `sandbox-exec` are the only ones that prove
# anything about *confinement* — everything else only proves what smith wrote
# into a string. They cost about 5 ms each and are skipped where the binary is
# not there, which is every platform but macOS.
private def with_sandbox_exec(&)
  {% if flag?(:darwin) %}
    yield if SANDBOX_EXEC_USABLE
  {% end %}
end

# Present, and applicable from here — the same trial run `smith doctor`
# performs, which is why it lives in src/ and not here any more.
#
# A sandbox cannot be nested. Inside one, `sandbox-exec` fails with
# `sandbox_apply: Operation not permitted`, so these specs have to stand down
# when the suite itself is being run confined — which is exactly what someone
# testing this feature will try first.
SANDBOX_EXEC_USABLE = Smith::Sandbox.probe.usable?

private def in_tempdir(&)
  dir = File.join(Dir.tempdir, "smith_sandbox_#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(File.join(dir, "work"))

  begin
    yield File.join(dir, "work"), dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe Smith::Sandbox::Policy do
  describe ".parse_network" do
    it "reads the three forms" do
      Smith::Sandbox::Policy.parse_network("allow").should eq({Smith::Sandbox::Network::Allow, [] of Int32})
      Smith::Sandbox::Policy.parse_network("deny").should eq({Smith::Sandbox::Network::Deny, [] of Int32})
      Smith::Sandbox::Policy.parse_network("ports:443, 80").should eq({Smith::Sandbox::Network::Ports, [443, 80]})
    end

    it "falls back to allowing rather than failing the start" do
      # The rest of the config takes the same posture: a value nobody can read
      # is a warning at worst, never a session that will not open.
      Smith::Sandbox::Policy.parse_network("nonsense").should eq({Smith::Sandbox::Network::Allow, [] of Int32})
      Smith::Sandbox::Policy.parse_network(nil).should eq({Smith::Sandbox::Network::Allow, [] of Int32})
    end

    it "reads ports with nothing usable in them as a denial" do
      # "ports:" said *something* about the network, and the safe reading of an
      # empty allowlist is that nothing is allowed.
      Smith::Sandbox::Policy.parse_network("ports:abc").should eq({Smith::Sandbox::Network::Deny, [] of Int32})
    end
  end
end

describe Smith::Sandbox::Off do
  it "hands the command to bash unchanged" do
    Smith::Sandbox::Off.new.wrap("echo hi").should eq({"/bin/bash", ["-c", "echo hi"]})
  end

  it "never claims a command is confined" do
    Smith::Sandbox::Off.new.sandboxed?("echo hi").should be_false
    Smith::Sandbox::Off.new.active?.should be_false
  end
end

describe Smith::Sandbox::MacOS do
  describe "the profile" do
    it "denies by default and confines writing to the working directory" do
      profile = macos("/project").profile

      profile.should contain("(deny default)")
      profile.should contain(%[(subpath "/project")])
      # Reading is not what a runaway command does damage with, and denying it
      # breaks every compiler on the machine.
      profile.should contain("(allow file-read*)")
    end

    it "expands ~ against the home directory, not the current one" do
      # Without `home: true` Crystal leaves the tilde in place and resolves the
      # rest against the working directory — a write allowance that allows
      # nothing, inside the project instead of in the cache.
      paths = macos("/project").write_paths

      paths.should contain(File.join(Path.home.to_s, ".cache"))
      paths.any?(&.includes?("~")).should be_false
    end

    it "carries the toolchain's cache directories by default" do
      # The finding that made this feature more than a profile string: without
      # ~/.cache a Crystal build fails as "you've found a bug in the Crystal
      # compiler", which is not a sentence anyone can act on.
      macos("/project").write_paths.should contain(File.join(Path.home.to_s, ".cache"))
    end

    it "adds configured paths to the defaults rather than replacing them" do
      paths = macos("/project", write: ["/extra"]).write_paths

      paths.should contain("/extra")
      paths.should contain("/private/tmp")
    end

    it "drops the defaults only when asked" do
      paths = macos("/project", write: ["/extra"], write_defaults: false).write_paths

      paths.should eq(["/project", "/extra"])
    end

    it "puts read denials after the read allowance, where they win" do
      profile = macos("/project", deny_read: ["/secrets"]).profile

      # SBPL takes the last matching rule, so the order is the rule.
      profile.index(%[(deny file-read* (subpath "/secrets"))]).not_nil!
        .should be > profile.index("(allow file-read*)").not_nil!
    end

    it "writes each network mode" do
      macos("/project").profile.should contain("(allow network*)")
      macos("/project", network: Smith::Sandbox::Network::Deny).profile.should contain("(deny network*)")

      ports = macos("/project", network: Smith::Sandbox::Network::Ports, ports: [443]).profile
      ports.should contain(%[(allow network-outbound (remote tcp "*:443"))])
      ports.index("(deny network*)").not_nil!.should be < ports.index(%[(remote tcp "*:443")]).not_nil!
    end

    it "escapes a path that would otherwise break out of its own string" do
      profile = macos(%q(/pro"ject), write_defaults: false).profile

      profile.should contain(%q[(subpath "/pro\"ject")])
    end
  end

  describe "#wrap" do
    it "runs the command through sandbox-exec as a single argv entry" do
      program, arguments = macos("/project").wrap("echo hi; echo there")

      program.should eq(Smith::Sandbox::MACOS_BINARY)
      arguments[0].should eq("-p")
      arguments[1].should contain("(deny default)")
      arguments[2].should eq("/bin/bash")
      arguments[3].should eq("-c")
      # One entry, so nothing here can turn the command into a second round of
      # shell parsing.
      arguments[4].should eq("echo hi; echo there")
    end

    it "leaves a command the user excused alone" do
      sandbox = macos("/project", unsandboxed: ["git push"])

      sandbox.sandboxed?("git push origin main").should be_false
      sandbox.wrap("git push origin main").should eq({"/bin/bash", ["-c", "git push origin main"]})

      # Prefix matching per segment, borrowed wholesale from the approval
      # allowlist: a second command smuggled in behind a `;` is its own
      # segment and has to be listed too.
      sandbox.sandboxed?("git push origin main; rm -rf /").should be_true
    end
  end
end

describe "the sandbox as the kernel enforces it" do
  it "allows a write inside the working directory" do
    with_sandbox_exec do
      in_tempdir do |work, _outer|
        program, arguments = Smith::Sandbox::MacOS.new(policy, work)
          .wrap("echo confined > #{work}/inside.txt")

        Process.run(program, arguments).success?.should be_true
        File.read(File.join(work, "inside.txt")).should eq("confined\n")
      end
    end
  end

  it "refuses a write next door" do
    with_sandbox_exec do
      in_tempdir do |work, outer|
        escape = File.join(outer, "outside.txt")
        program, arguments = Smith::Sandbox::MacOS.new(policy(write_defaults: false), work)
          .wrap("echo escaped > #{escape}")

        error = IO::Memory.new
        Process.run(program, arguments, error: error).success?.should be_false
        error.to_s.should contain("Operation not permitted")
        File.exists?(escape).should be_false
      end
    end
  end

  it "refuses to delete a file outside" do
    with_sandbox_exec do
      in_tempdir do |work, outer|
        victim = File.join(outer, "keep.txt")
        File.write(victim, "still here")

        program, arguments = Smith::Sandbox::MacOS.new(policy(write_defaults: false), work)
          .wrap("rm -f #{victim}")

        Process.run(program, arguments, error: Process::Redirect::Close).success?.should be_false
        File.read(victim).should eq("still here")
      end
    end
  end

  it "hides a path named in deny_read" do
    with_sandbox_exec do
      in_tempdir do |work, outer|
        secret_dir = File.join(outer, "secrets")
        FileUtils.mkdir_p(secret_dir)
        File.write(File.join(secret_dir, "key"), "sensitive")

        program, arguments = Smith::Sandbox::MacOS.new(policy(deny_read: [secret_dir]), work)
          .wrap("cat #{secret_dir}/key")

        output = IO::Memory.new
        Process.run(program, arguments, output: output, error: Process::Redirect::Close)
        output.to_s.should_not contain("sensitive")
      end
    end
  end
end

describe "Smith::Sandbox.build" do
  it "is off when nobody asked for it" do
    Smith::Sandbox.build(Smith::Sandbox::Policy.new(enabled: false), "/project").active?.should be_false
  end

  it "says why, when it cannot be what was asked for" do
    strategy = Smith::Sandbox.build(Smith::Sandbox::Policy.new(enabled: true), "/project")

    {% if flag?(:darwin) %}
      if File.exists?(Smith::Sandbox::MACOS_BINARY)
        strategy.active?.should be_true
      else
        strategy.describe.should contain("missing")
      end
    {% else %}
      # Never silently unprotected: a sandbox that was asked for and is not
      # there has to say so, or "on" stops meaning anything.
      strategy.active?.should be_false
      strategy.describe.should contain("macOS")
    {% end %}
  end
end

describe ".probe" do
  it "answers with a status and a reason on every platform" do
    # Shape only: `sandbox-exec` exists on macOS and nowhere else, so a spec
    # that asserted an outcome would be a spec that fails on the other CI leg.
    probe = Smith::Sandbox.probe

    probe.detail.should_not be_empty
    Smith::Sandbox::Availability.values.should contain(probe.availability)
    probe.usable?.should eq(probe.availability.usable?)

    {% if !flag?(:darwin) %}
      # Nothing here confines bash yet, and claiming otherwise is the one
      # failure this check exists to prevent.
      probe.usable?.should be_false
    {% end %}
  end

  it "comes back well inside its deadline" do
    started = Time.instant
    Smith::Sandbox.probe
    (Time.instant - started).should be < Smith::Sandbox::PROBE_TIMEOUT * 2
  end
end
