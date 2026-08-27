require "./tools/approval"
require "./tools/permissions"

# Runs `bash` where it cannot reach past the project.
#
# The approval gate asks before every mutating call, and asking about
# everything is how users end up leaving `--yes` on — at which point nothing
# is gated at all. A sandbox inverts that: a command that *cannot* write
# outside the working directory does not need to be asked about, because the
# answer no longer depends on trust.
#
# What is claimed here is deliberately narrow. The filesystem is confined and
# the network is a switch. There is no per-domain allowlist, because SBPL
# filters by address and port and not by hostname — a profile naming a host
# does not compile. Saying so is better than a setting that quietly means
# something else.
module Smith::Sandbox
  # What a sandboxed command may do with the network.
  #
  # `Allow` is the default, and it is a considered one: `deny network*` also
  # stops `git fetch`, `git push` and every package manager, and a sandbox
  # that breaks the working day is a sandbox the user switches off — losing
  # the filesystem confinement along with it.
  enum Network
    Allow
    Deny
    Ports
  end

  # Directories the toolchain has to write to or it fails — usually not with a
  # permission error but with something far more confusing. A Crystal compiler
  # that cannot write `~/.cache/crystal` reports "you've found a bug in the
  # Crystal compiler", which is a sentence that sends an agent hunting through
  # its own code for an hour.
  #
  # This list is the reason the feature is more than a profile string.
  DEFAULT_WRITE_PATHS = [
    "/private/tmp",
    "/private/var/tmp",
    "~/.cache",
    "~/Library/Caches",
    "~/.npm",
    "~/.cargo",
    "~/.local/share",
    "~/.local/state",
  ]

  # Character devices a shell needs to be a shell.
  DEVICE_WRITE_PATHS = [
    "/dev/null",
    "/dev/stdout",
    "/dev/stderr",
    "/dev/urandom",
    "/dev/dtracehelper",
    "/dev/tty",
  ]

  MACOS_BINARY = "/usr/bin/sandbox-exec"

  struct Policy
    getter? enabled : Bool
    getter? auto_approve : Bool
    getter? required : Bool
    getter network : Network
    getter ports : Array(Int32)
    getter write : Array(String)

    # Whether DEFAULT_WRITE_PATHS still apply. `write` adds to them rather
    # than replacing them: the first path somebody adds must not be the moment
    # their build stops working.
    getter? write_defaults : Bool

    getter deny_read : Array(String)

    # Command prefixes that run outside the sandbox. `git push` and
    # `npm install` are the everyday reasons someone would otherwise turn the
    # whole thing off.
    getter unsandboxed : Array(String)

    def initialize(
      @enabled : Bool = false,
      @auto_approve : Bool = false,
      @required : Bool = false,
      @network : Network = Network::Allow,
      @ports : Array(Int32) = [] of Int32,
      @write : Array(String) = [] of String,
      @write_defaults : Bool = true,
      @deny_read : Array(String) = [] of String,
      @unsandboxed : Array(String) = [] of String,
    )
    end

    # "allow" | "deny" | "ports:443,80". An unreadable value falls back to the
    # default rather than failing the start — the same posture the rest of the
    # config takes.
    def self.parse_network(raw : String?) : {Network, Array(Int32)}
      value = raw.try(&.strip.downcase)
      return {Network::Allow, [] of Int32} if value.nil? || value.empty?

      case value
      when "allow", "true", "on"  then {Network::Allow, [] of Int32}
      when "deny", "false", "off" then {Network::Deny, [] of Int32}
      else
        unless value.starts_with?("ports:")
          return {Network::Allow, [] of Int32}
        end

        ports = value.lchop("ports:").split(',').compact_map(&.strip.to_i?)
        ports.empty? ? {Network::Deny, [] of Int32} : {Network::Ports, ports}
      end
    end
  end

  # How a command is turned into a process. One implementation confines it,
  # the other does not — and says so, rather than pretending.
  abstract class Strategy
    abstract def name : String
    abstract def active? : Bool

    # Program and arguments, kept apart. The command stays a single argv entry
    # handed to `bash -c`, so nothing here can turn it into a second round of
    # shell parsing.
    abstract def wrap(command : String) : Tuple(String, Array(String))

    # Whether *this* command would actually be confined. False for everything
    # when the strategy is off, and false for a command the user listed as
    # unsandboxed.
    def sandboxed?(command : String) : Bool
      false
    end

    # One line for `smith sandbox` and the startup banner.
    abstract def describe : String
  end

  # No confinement: the sandbox is off, unsupported, or unavailable.
  class Off < Strategy
    getter reason : String?

    def initialize(@reason : String? = nil)
    end

    def name : String
      "off"
    end

    def active? : Bool
      false
    end

    def wrap(command : String) : Tuple(String, Array(String))
      {"/bin/bash", ["-c", command]}
    end

    def describe : String
      @reason || "off — bash runs with your full rights"
    end
  end

  # macOS, via `sandbox-exec` and a generated SBPL profile.
  #
  # `sandbox-exec` is documented as deprecated and has been shipping anyway;
  # measured on macOS 26.5.2 it costs about 5 ms per call and prints nothing.
  # The deprecation is a reason to keep this behind `Strategy` — the day the
  # binary is gone, `available?` says so and smith degrades out loud.
  class MacOS < Strategy
    getter policy : Policy
    getter write_paths : Array(String)
    getter deny_read : Array(String)

    def initialize(@policy : Policy, @workdir : String)
      @write_paths = build_write_paths
      @deny_read = @policy.deny_read.map { |path| Sandbox.absolute(path) }.uniq
    end

    def self.available? : Bool
      {% if flag?(:darwin) %}
        File.exists?(MACOS_BINARY)
      {% else %}
        false
      {% end %}
    end

    def name : String
      "sandbox-exec"
    end

    def active? : Bool
      true
    end

    def sandboxed?(command : String) : Bool
      !Smith::Tools::AllowList.allows?(command, @policy.unsandboxed)
    end

    def wrap(command : String) : Tuple(String, Array(String))
      return {"/bin/bash", ["-c", command]} unless sandboxed?(command)

      {MACOS_BINARY, ["-p", profile, "/bin/bash", "-c", command]}
    end

    def describe : String
      network = case @policy.network
                in Network::Allow then "network allowed"
                in Network::Deny  then "network denied"
                in Network::Ports then "network limited to port#{@policy.ports.size == 1 ? "" : "s"} #{@policy.ports.join(", ")}"
                end

      "sandbox-exec — writes confined to #{@write_paths.size} path#{@write_paths.size == 1 ? "" : "s"}, #{network}"
    end

    # The profile, as SBPL. Passed with `-p`, so there is no file to create,
    # find again or clean up.
    #
    # Order matters: SBPL takes the *last* matching rule, which is why the
    # read denials come after the blanket read allowance and the port
    # allowance after `deny network*`.
    def profile : String
      String.build do |sbpl|
        sbpl << "(version 1)\n"
        sbpl << "(deny default)\n"

        # Without these a shell cannot fork, resolve a name, or read the
        # system configuration it starts up with.
        sbpl << "(allow process*)\n"
        sbpl << "(allow sysctl-read)\n"
        sbpl << "(allow mach-lookup)\n"
        sbpl << "(allow signal)\n"

        # Reading is not what a runaway command does damage with, and denying
        # it breaks every compiler on the machine. Only the paths the user
        # named as secret are taken back out.
        sbpl << "(allow file-read*)\n"
        @deny_read.each do |path|
          sbpl << "(deny file-read* (subpath " << quote(path) << "))\n"
        end

        sbpl << "(allow file-write*"
        @write_paths.each { |path| sbpl << "\n  (subpath " << quote(path) << ")" }
        DEVICE_WRITE_PATHS.each { |path| sbpl << "\n  (literal " << quote(path) << ")" }
        sbpl << ")\n"

        case @policy.network
        in Network::Allow
          sbpl << "(allow network*)\n"
        in Network::Deny
          sbpl << "(deny network*)\n"
        in Network::Ports
          sbpl << "(deny network*)\n"
          sbpl << "(allow network-outbound (remote unix-socket))\n"
          @policy.ports.each do |port|
            sbpl << "(allow network-outbound (remote tcp " << quote("*:#{port}") << "))\n"
          end
        end
      end
    end

    private def build_write_paths : Array(String)
      paths = [Sandbox.absolute(@workdir)]

      if @policy.write_defaults?
        paths.concat(DEFAULT_WRITE_PATHS.map { |path| Sandbox.absolute(path) })

        # Not a constant, because on macOS it is per-user and per-boot:
        # `/var/folders/…/T`. Leaving it out is not a small gap — `clang`
        # cannot link without it, so every Crystal build inside the sandbox
        # fails with "unable to make temporary file", which reads like a
        # broken toolchain rather than a policy decision.
        if tmpdir = ENV["TMPDIR"]?
          paths << Sandbox.absolute(tmpdir) unless tmpdir.empty?
        end
      end

      paths.concat(@policy.write.map { |path| Sandbox.absolute(path) })
      paths.uniq
    end

    # An SBPL string is double-quoted, so a path carrying a quote or a
    # backslash would otherwise end the string early and turn the rest of the
    # path into syntax.
    private def quote(value : String) : String
      escaped = value.gsub('\\', "\\\\").gsub('"', "\\\"")
      "\"#{escaped}\""
    end
  end

  # A path as the kernel will see it.
  #
  # Two corrections, both of which are silent failures if skipped. `~` is left
  # alone by `File.expand_path` unless it is told otherwise, which turns
  # `~/.cache` into a path *inside the project*: an allowance that allows
  # nothing. And symlinks have to be resolved, because the sandbox matches the
  # real path — on macOS `/tmp` is `/private/tmp` and a temporary directory
  # lives under `/private/var/folders`, so a profile naming the unresolved
  # path confines a directory nobody is writing to.
  #
  # `Tools::Paths.normalize` already does the symlink half for permission
  # rules, where getting it wrong is how a scoped rule gets bypassed. Same
  # problem, same code.
  def self.absolute(path : String) : String
    Smith::Tools::Paths.normalize(File.expand_path(path, home: true), "/")
  end

  # The strategy for this policy on this machine, and the reason when it is
  # not the one that was asked for.
  def self.build(policy : Policy, workdir : String = Dir.current) : Strategy
    return Off.new unless policy.enabled?

    unless MacOS.available?
      {% if flag?(:darwin) %}
        return Off.new("requested, but #{MACOS_BINARY} is missing — bash runs with your full rights")
      {% else %}
        return Off.new("requested, but smith only has a sandbox for macOS — bash runs with your full rights")
      {% end %}
    end

    MacOS.new(policy, workdir)
  end
end
