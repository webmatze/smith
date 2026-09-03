require "digest/sha256"
require "file_utils"
require "http/client"
require "json"
require "uri"
require "./version"
require "./web/guard"

module Smith
  # `smith update` — replaces the running executable with the newest release
  # binary.
  #
  # Everything that touches the network sits behind `Source`; everything that
  # decides *whether* to act is a pure function on this module. That split is
  # what lets the specs cover the interesting half without a socket, and it is
  # also why every refusal below happens before a single request goes out.
  module Update
    REPO            = "webmatze/smith"
    LATEST_ENDPOINT = "https://api.github.com/repos/#{REPO}/releases/latest"

    # The channel a release build stamps into itself; see Smith::BUILD_CHANNEL.
    RELEASE_CHANNEL = "release"

    # Attached by .github/workflows/release.yml alongside the archives.
    CHECKSUM_ASSET = "SHA256SUMS"

    MAX_REDIRECTS = 5
    MAX_METADATA  = 1024 * 1024
    MAX_ARCHIVE   = 64 * 1024 * 1024

    class Error < Exception
    end

    # ---------------------------------------------------------------- version

    # A release tag, strictly `MAJOR.MINOR.PATCH` with an optional `v`.
    #
    # Deliberately unforgiving: a tag this cannot read is reported as
    # incomparable rather than coerced, because the fallback for a coerced tag
    # is 0.0.0, and 0.0.0 means "every build is newer than the release" —
    # exactly the wrong way for a mistake to go when the outcome is
    # overwriting an executable.
    struct SemVer
      include Comparable(SemVer)

      PATTERN = /\Av?(\d+)\.(\d+)\.(\d+)\z/

      getter major : Int32
      getter minor : Int32
      getter patch : Int32

      def initialize(@major : Int32, @minor : Int32, @patch : Int32)
      end

      def self.parse?(raw : String) : SemVer?
        match = PATTERN.match(raw.strip)
        return nil if match.nil?

        new(match[1].to_i, match[2].to_i, match[3].to_i)
      rescue ArgumentError
        # A segment too large for Int32 is not a version smith ships.
        nil
      end

      def <=>(other : SemVer) : Int32
        {major, minor, patch} <=> {other.major, other.minor, other.patch}
      end

      def to_s(io : IO) : Nil
        io << major << '.' << minor << '.' << patch
      end
    end

    enum Comparison
      Newer   # the release is newer than this build
      Current # the same version
      Ahead   # this build is newer than the newest release
      Unknown # one of the two cannot be read as a version
    end

    def self.compare(current : String, tag : String) : Comparison
      local = SemVer.parse?(current)
      remote = SemVer.parse?(tag)
      return Comparison::Unknown if local.nil? || remote.nil?

      case remote <=> local
      when .positive? then Comparison::Newer
      when .negative? then Comparison::Ahead
      else                 Comparison::Current
      end
    end

    def self.release_build?(channel : String) : Bool
      channel == RELEASE_CHANNEL
    end

    def self.describe_channel(channel : String) : String
      release_build?(channel) ? "release build" : "dev build"
    end

    # --------------------------------------------------------------- platform

    module Platform
      # Resolved by the compiler for the machine this binary was built for,
      # which is the only machine it can run on anyway.
      HOST_OS   = {{ flag?(:darwin) ? "darwin" : (flag?(:linux) ? "linux" : "unknown") }}
      HOST_ARCH = {{ flag?(:aarch64) ? "arm64" : (flag?(:x86_64) ? "x86_64" : "unknown") }}

      # Exactly what release.yml builds — no more, and nothing guessed.
      TARGETS = %w[linux-x86_64 darwin-arm64 darwin-x86_64]

      def self.target?(os : String, arch : String) : String?
        normalized_os = normalize_os(os)
        normalized_arch = normalize_arch(arch)
        return nil if normalized_os.nil? || normalized_arch.nil?

        candidate = "#{normalized_os}-#{normalized_arch}"
        TARGETS.includes?(candidate) ? candidate : nil
      end

      def self.host_target? : String?
        target?(HOST_OS, HOST_ARCH)
      end

      private def self.normalize_os(os : String) : String?
        case os.strip.downcase
        when "darwin", "macos", "mac os x", "osx" then "darwin"
        when "linux"                              then "linux"
        end
      end

      private def self.normalize_arch(arch : String) : String?
        case arch.strip.downcase
        when "x86_64", "amd64", "x64" then "x86_64"
        when "arm64", "aarch64"       then "arm64"
        end
      end
    end

    def self.archive_name(tag : String, target : String) : String
      "smith-#{tag}-#{target}.tar.gz"
    end

    # --------------------------------------------------------- release metadata

    struct Asset
      getter name : String
      getter url : String

      def initialize(@name : String, @url : String)
      end
    end

    struct Release
      getter tag : String
      getter assets : Array(Asset)

      def initialize(@tag : String, @assets : Array(Asset) = [] of Asset)
      end

      def asset?(name : String) : Asset?
        assets.find { |asset| asset.name == name }
      end

      # nil rather than an exception: a malformed answer from the API is an
      # ordinary failure mode, and the caller turns it into a message.
      def self.from_json?(body : String) : Release?
        json = begin
          JSON.parse(body)
        rescue JSON::ParseException
          return nil
        end

        tag = json["tag_name"]?.try(&.as_s?)
        return nil if tag.nil? || tag.empty?

        assets = [] of Asset
        json["assets"]?.try(&.as_a?).try &.each do |raw|
          name = raw["name"]?.try(&.as_s?)
          url = raw["browser_download_url"]?.try(&.as_s?)
          assets << Asset.new(name, url) if name && url
        end

        new(tag, assets)
      end
    end

    # -------------------------------------------------------------- checksums

    module Checksums
      LINE = /\A([0-9a-fA-F]{64})\s+\*?(\S.*)\z/

      # `sha256sum` output: one `<digest>  <name>` line per file, `*` marking
      # binary mode. Anything else on a line is skipped rather than fatal, so a
      # future header or signature block does not break verification.
      def self.parse(text : String) : Hash(String, String)
        sums = {} of String => String

        text.each_line do |line|
          match = LINE.match(line.strip)
          next if match.nil?

          name = File.basename(match[2].strip)
          sums[name] = match[1].downcase unless name.empty?
        end

        sums
      end

      # nil when the archive matches, otherwise the reason it does not.
      def self.verify(sums : Hash(String, String), name : String, digest : String) : String?
        expected = sums[name]?
        return "#{name} is not listed in #{CHECKSUM_ASSET}" if expected.nil?
        return nil if expected == digest.downcase

        "checksum mismatch for #{name}: #{CHECKSUM_ASSET} says #{expected}, the download hashes to #{digest.downcase}"
      end
    end

    # --------------------------------------------------------- install target

    # What kind of installation the running binary belongs to. Only
    # `SelfManaged` may be replaced; the rest are somebody else's to update,
    # and guessing at one of them is how a package manager's next command
    # silently undoes the update — or fails outright.
    enum Install
      SelfManaged
      Homebrew
      Nix
      SystemPath
      ReadOnly
    end

    # Directories a distribution owns. `/usr/local` is deliberately absent:
    # that tree exists for exactly the hand-placed binaries this command is for.
    SYSTEM_PREFIXES = %w[/usr/bin/ /bin/ /usr/sbin/ /sbin/ /opt/local/bin/]

    # `path` is expected to be resolved already — Homebrew links
    # `<prefix>/bin/smith` to `<prefix>/Cellar/smith/<version>/bin/smith`, and
    # the Cellar is what identifies it.
    def self.classify(path : String, dir_writable : Bool, homebrew_prefix : String? = nil) : Install
      return Install::Homebrew if homebrew?(path, homebrew_prefix)
      return Install::Nix if path.starts_with?("/nix/store/")
      return Install::SystemPath if SYSTEM_PREFIXES.any? { |prefix| path.starts_with?(prefix) }
      return Install::ReadOnly unless dir_writable

      Install::SelfManaged
    end

    private def self.homebrew?(path : String, homebrew_prefix : String?) : Bool
      return true if path.includes?("/Cellar/")
      return true if path.starts_with?("/opt/homebrew/")
      return true if path.starts_with?("/home/linuxbrew/.linuxbrew/")

      prefix = homebrew_prefix
      return false if prefix.nil? || prefix.empty?

      path.starts_with?(File.join(prefix, "Cellar") + "/")
    end

    # What to tell the user instead of updating.
    def self.advice(install : Install, path : String) : String
      case install
      in Install::Homebrew
        "Homebrew owns this binary. Update it with `brew upgrade smith` — replacing it behind Homebrew's back is undone by the next `brew` command."
      in Install::Nix
        "This binary lives in the read-only Nix store. Update it through the flake or channel that provides it."
      in Install::SystemPath
        "#{File.dirname(path)} belongs to your distribution's package manager. Update smith with that, or install a release binary into ~/.local/bin instead."
      in Install::ReadOnly
        "#{File.dirname(path)} is not writable by the current user, and smith will not ask for privileges it was not started with. Re-run as the owner, or install a release binary into ~/.local/bin instead."
      in Install::SelfManaged
        ""
      end
    end

    # ------------------------------------------------------------ URL policy

    # Smith::Web::Guard is this project's one URL policy and it stays that: the
    # scheme allow-list plus the address check *after* DNS resolution. Two
    # things differ for a release download, and both tighten it.
    #
    # `Guard.normalize` upgrades http to https as a convenience for a URL a
    # human typed. An asset URL is not typed — it comes out of an API answer —
    # so a non-https one is a fault to refuse, not a typo to fix.
    #
    # And this *must* follow the redirect from github.com to
    # objects.githubusercontent.com, which `WebFetch` deliberately refuses as a
    # cross-host hop. So the hop count is capped and every hop is put back
    # through the guard from scratch.
    def self.https_reason(raw : String) : String?
      uri = begin
        URI.parse(raw)
      rescue URI::Error
        return "#{raw.inspect} is not a valid URL"
      end

      scheme = uri.scheme
      unless scheme == "https"
        return "#{raw.inspect} is not an https URL (scheme #{scheme.inspect}); smith downloads releases over https only"
      end

      host = uri.host
      return "#{raw.inspect} has no host" if host.nil? || host.empty?

      nil
    end

    # ------------------------------------------------------------ the network

    # The one seam the specs replace. Nothing else in this file opens a socket.
    abstract class Source
      abstract def latest_release : Release
      abstract def fetch(asset : Asset) : Bytes
    end

    class GitHubSource < Source
      def initialize(@connect_timeout : Int32 = 10, @read_timeout : Int32 = 60)
      end

      def latest_release : Release
        body = String.new(get(LATEST_ENDPOINT, MAX_METADATA))
        Release.from_json?(body) || raise Error.new("#{LATEST_ENDPOINT} did not answer with a readable release")
      end

      def fetch(asset : Asset) : Bytes
        get(asset.url, MAX_ARCHIVE)
      end

      private def get(url : String, max_bytes : Int32, redirects : Int32 = 0) : Bytes
        raise Error.new("too many redirects (more than #{MAX_REDIRECTS}) fetching #{url}") if redirects > MAX_REDIRECTS

        if reason = Update.https_reason(url)
          raise Error.new(reason)
        end

        uri = URI.parse(url)
        if reason = Web::Guard.check(uri)
          raise Error.new(reason)
        end

        begin
          client_for(uri) do |client|
            client.get(uri.request_target, headers: headers) do |response|
              if response.status.redirection?
                location = response.headers["Location"]?
                raise Error.new("#{url} answered #{response.status_code} without a Location header") if location.nil?

                return get(uri.resolve(location).to_s, max_bytes, redirects + 1)
              end

              unless response.status.success?
                raise Error.new("#{url} returned HTTP #{response.status_code} #{response.status.description}")
              end

              read_bounded(response.body_io, max_bytes, url)
            end
          end
        rescue ex : Error
          raise ex
        rescue ex : Exception
          # A TLS failure, a DNS race, a truncated connection — the command
          # turns an Error into one line, and a stack trace helps nobody who
          # is only trying to install a binary.
          raise Error.new("could not reach #{uri.host}: #{ex.message}")
        end
      end

      # The archives are a few megabytes; a body that is not is either the
      # wrong URL or hostile, and neither is worth buffering.
      private def read_bounded(io : IO, max_bytes : Int32, url : String) : Bytes
        buffer = IO::Memory.new
        copied = IO.copy(io, buffer, max_bytes + 1)
        raise Error.new("#{url} is larger than #{max_bytes // (1024 * 1024)} MiB; refusing to download it") if copied > max_bytes

        buffer.to_slice
      end

      private def headers : HTTP::Headers
        # api.github.com answers 403 without a User-Agent.
        HTTP::Headers{
          "User-Agent" => "smith/#{Smith::VERSION}",
          "Accept"     => "application/vnd.github+json, application/octet-stream;q=0.9, */*;q=0.1",
        }
      end

      private def client_for(uri : URI, &)
        client = HTTP::Client.new(uri)
        client.connect_timeout = @connect_timeout.seconds
        client.read_timeout = @read_timeout.seconds
        begin
          yield client
        ensure
          client.close
        end
      end
    end

    # -------------------------------------------------------- the replacement

    # Replacing a *running* executable is not the same problem as writing a
    # config file, which is why this is not Smith::AtomicFile.
    #
    # The file cannot be written in place: Linux refuses to open a busy binary
    # for writing (ETXTBSY) and macOS kills the process whose signed image was
    # modified underneath it. Renaming over it is fine on both — the running
    # process keeps the old inode until it exits. That makes the staging
    # directory's location load-bearing: rename is only atomic within one
    # filesystem, so it has to sit next to the target rather than in /tmp.
    class Installer
      def initialize(@target : String)
      end

      def install(archive : Bytes) : Nil
        dir = File.dirname(@target)
        staging = File.join(dir, ".smith-update-#{Random::Secure.hex(6)}")

        begin
          FileUtils.mkdir_p(staging, mode: 0o700)
          archive_path = File.join(staging, "archive.tar.gz")
          File.write(archive_path, archive)

          extract(archive_path, staging)

          binary = File.join(staging, "smith")
          raise Error.new("the archive does not contain a 'smith' binary") unless File.file?(binary)
          raise Error.new("the 'smith' binary in the archive is empty") if File.size(binary).zero?

          File.chmod(binary, 0o755)
          File.rename(binary, @target)
        rescue ex : File::Error
          raise Error.new("could not replace #{@target}: #{ex.message}")
        ensure
          FileUtils.rm_rf(staging)
        end
      end

      # Only the `smith` member is unpacked, which is also what keeps a
      # tampered archive from writing anywhere but the staging directory.
      private def extract(archive : String, into : String) : Nil
        errors = IO::Memory.new

        status = begin
          Process.run("tar", ["-xzf", archive, "-C", into, "smith"], output: Process::Redirect::Close, error: errors)
        rescue ex : IO::Error
          raise Error.new("could not run tar to unpack the release archive: #{ex.message}")
        end

        return if status.success?

        raise Error.new("tar could not unpack the release archive: #{errors.to_s.strip.presence || "exit status #{status.exit_code}"}")
      end
    end

    # ------------------------------------------------------------- the command

    struct Location
      getter path : String
      getter install : Install

      def initialize(@path : String, @install : Install)
      end
    end

    class Command
      def initialize(
        @check_only : Bool = false,
        @source : Source = GitHubSource.new,
        @channel : String = Smith::BUILD_CHANNEL,
        @current : String = Smith::VERSION,
        @target : String? = nil,
        @io : IO = STDOUT,
        @err : IO = STDERR,
      )
      end

      def run : Int32
        @check_only ? check : update
      rescue ex : Error
        @err.puts "❌ Error: #{ex.message}"
        1
      end

      # --check reports and returns; it never refuses, because "you cannot
      # update this install" is precisely the thing it is being asked.
      private def check : Int32
        @io.puts "⚒️  smith #{@current} — #{Update.describe_channel(@channel)}"

        location = locate
        if location
          @io.puts "   Installed at #{location.path}"
          @io.puts "   #{Update.advice(location.install, location.path)}" unless location.install.self_managed?
        end

        release = @source.latest_release

        case Update.compare(@current, release.tag)
        when .newer?
          @io.puts "⬆️  #{release.tag} is available."
          @io.puts "   Run `smith update` to install it." if updatable?(location)
        when .current?
          @io.puts "✅ #{release.tag} is the newest release; this build is up to date."
        when .ahead?
          @io.puts "✅ This build is ahead of the newest release (#{release.tag})."
        else
          @err.puts "⚠️  The newest release is tagged #{release.tag.inspect}, which smith cannot compare against #{@current}."
        end

        0
      end

      private def update : Int32
        # First, and offline on purpose: a build that did not come from a
        # release must refuse before it can do any damage, network or not.
        unless Update.release_build?(@channel)
          @err.puts "❌ Error: this smith is a #{Update.describe_channel(@channel)}, not a binary installed from a release."
          @err.puts "   `smith update` only replaces binaries that CI built and attached to a GitHub release. It has no"
          @err.puts "   idea what went into this one, so overwriting it would throw away a build nothing can reproduce."
          @err.puts "   Rebuild from source instead:  make build   (or: crystal build src/smith.cr -o bin/smith)"
          return 1
        end

        location = locate
        if location.nil?
          @err.puts "❌ Error: smith cannot tell where its own binary is, so it will not replace anything."
          return 1
        end

        unless location.install.self_managed?
          @err.puts "❌ Error: #{location.path} is not smith's to replace."
          @err.puts "   #{Update.advice(location.install, location.path)}"
          return 1
        end

        target = Platform.host_target?
        if target.nil?
          @err.puts "❌ Error: releases carry no binary for #{Platform::HOST_OS}/#{Platform::HOST_ARCH}."
          @err.puts "   Built targets are #{Platform::TARGETS.join(", ")}. Build from source instead."
          return 1
        end

        release = @source.latest_release

        case Update.compare(@current, release.tag)
        when .current?
          @io.puts "✅ smith #{@current} is already the newest release."
          return 0
        when .ahead?
          @io.puts "✅ smith #{@current} is newer than the newest release (#{release.tag}); nothing to update."
          return 0
        when .unknown?
          @err.puts "❌ Error: the newest release is tagged #{release.tag.inspect}, which smith cannot compare against #{@current}."
          @err.puts "   Refusing to guess which of the two is newer. Install it by hand if you want it."
          return 1
        end

        name = Update.archive_name(release.tag, target)
        asset = release.asset?(name)
        if asset.nil?
          @err.puts "❌ Error: release #{release.tag} carries no #{name}."
          @err.puts "   It has: #{release.assets.map(&.name).join(", ").presence || "no assets at all"}"
          return 1
        end

        @io.puts "⬇️  Downloading #{asset.name} …"
        archive = @source.fetch(asset)
        digest = Digest::SHA256.hexdigest(archive)

        sums_asset = release.asset?(CHECKSUM_ASSET)
        if sums_asset.nil?
          # Releases cut before #96 have nothing to check against, and that
          # will never change for them — so say so plainly instead of implying
          # a verification that did not happen.
          @err.puts "⚠️  Release #{release.tag} carries no #{CHECKSUM_ASSET}; this download cannot be verified."
          @err.puts "   All that stands behind it is the HTTPS connection to #{URI.parse(asset.url).host}."
        else
          sums = Checksums.parse(String.new(@source.fetch(sums_asset)))
          if reason = Checksums.verify(sums, asset.name, digest)
            @err.puts "❌ Error: #{reason}."
            @err.puts "   #{location.path} was left untouched."
            return 1
          end
          @io.puts "🔐 SHA-256 matches #{CHECKSUM_ASSET}: #{digest[0, 16]}…"
        end

        Installer.new(location.path).install(archive)

        @io.puts "✅ Updated #{location.path}: #{@current} → #{release.tag}."
        @io.puts "   This process still runs the old binary; the next `smith` picks up the new one."
        0
      end

      private def updatable?(location : Location?) : Bool
        Update.release_build?(@channel) && !location.nil? && location.install.self_managed?
      end

      # Where the running binary actually is, and whether it may be replaced.
      # Nothing here touches the network.
      private def locate : Location?
        raw = @target || Process.executable_path
        return nil if raw.nil?

        # Resolved, because ~/.local/bin/smith may well be a symlink and the
        # file the link points at is the one that has to be replaced.
        path = begin
          File.realpath(raw)
        rescue File::Error
          raw
        end

        writable = begin
          File::Info.writable?(File.dirname(path))
        rescue File::Error
          false
        end

        Location.new(path, Update.classify(path, dir_writable: writable, homebrew_prefix: ENV["HOMEBREW_PREFIX"]?))
      end
    end
  end
end
