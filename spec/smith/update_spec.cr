require "../spec_helper"
require "../../src/smith/update"

# The one seam that would otherwise reach GitHub. No spec in this file opens a
# socket; the decision logic is all pure and driven directly.
private class FakeSource < Smith::Update::Source
  getter fetched = [] of String
  getter caps = {} of String => Int32

  def initialize(@release : Smith::Update::Release, @bodies : Hash(String, Bytes) = {} of String => Bytes)
  end

  def latest_release : Smith::Update::Release
    @release
  end

  def fetch(asset : Smith::Update::Asset, max_bytes : Int32) : Bytes
    @fetched << asset.name
    @caps[asset.name] = max_bytes
    @bodies[asset.name]? || raise Smith::Update::Error.new("no fixture for #{asset.name}")
  end
end

private class FailingSource < Smith::Update::Source
  def latest_release : Smith::Update::Release
    raise Smith::Update::Error.new("could not reach api.github.com: nope")
  end

  def fetch(asset : Smith::Update::Asset, max_bytes : Int32) : Bytes
    raise Smith::Update::Error.new("unreachable")
  end
end

# A directory nothing outside the spec can see. Every path below lives here.
private def with_temp_dir(&)
  dir = File.join(Dir.tempdir, "smith_update_spec_#{Random::Secure.hex(6)}")
  FileUtils.mkdir_p(dir)
  begin
    yield File.realpath(dir)
  ensure
    FileUtils.rm_rf(dir)
  end
end

# Builds a release archive of the shape release.yml produces: a gzipped tar
# holding exactly one file called `smith`.
private def build_archive(dir : String, content : String) : Bytes
  staging = File.join(dir, "pack_#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(staging)
  File.write(File.join(staging, "smith"), content)
  File.chmod(File.join(staging, "smith"), 0o755)

  archive = File.join(dir, "archive_#{Random::Secure.hex(4)}.tar.gz")
  status = Process.run("tar", ["-czf", archive, "-C", staging, "smith"])
  raise "could not build the fixture archive" unless status.success?

  File.read(archive).to_slice
end

# Packs an archive whose `smith` member is a symlink to `victim`, stored under
# `member` so the `./`-prefixed spelling can be tried too.
private def symlink_archive(dir : String, victim : String, member : String) : String
  evil = File.join(dir, "evil_#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(evil)
  File.symlink(victim, File.join(evil, "smith"))

  archive = File.join(dir, "evil_#{Random::Secure.hex(4)}.tar.gz")
  Process.run("tar", ["-czf", archive, "-C", evil, member])
  archive
end

describe Smith::Update::SemVer do
  it "reads a plain and a v-prefixed tag the same way" do
    Smith::Update::SemVer.parse?("1.2.3").should eq(Smith::Update::SemVer.new(1, 2, 3))
    Smith::Update::SemVer.parse?("v1.2.3").should eq(Smith::Update::SemVer.new(1, 2, 3))
    Smith::Update::SemVer.parse?(" v0.4.0 ").to_s.should eq("0.4.0")
  end

  it "refuses anything that is not exactly three numbers" do
    Smith::Update::SemVer.parse?("nightly").should be_nil
    Smith::Update::SemVer.parse?("1.2").should be_nil
    Smith::Update::SemVer.parse?("v1.2.3-rc1").should be_nil
    Smith::Update::SemVer.parse?("").should be_nil
    Smith::Update::SemVer.parse?("v1.2.3.4").should be_nil
  end

  it "orders by major, then minor, then patch" do
    (Smith::Update::SemVer.new(0, 5, 0) > Smith::Update::SemVer.new(0, 4, 9)).should be_true
    (Smith::Update::SemVer.new(1, 0, 0) > Smith::Update::SemVer.new(0, 99, 99)).should be_true
    (Smith::Update::SemVer.new(0, 4, 10) > Smith::Update::SemVer.new(0, 4, 9)).should be_true
  end
end

describe "Smith::Update.compare" do
  it "sees a newer release" do
    Smith::Update.compare("0.4.0", "v0.5.0").should eq(Smith::Update::Comparison::Newer)
  end

  it "sees equal versions through the v prefix" do
    Smith::Update.compare("0.4.0", "v0.4.0").should eq(Smith::Update::Comparison::Current)
  end

  it "sees a local build that is ahead of the newest release" do
    Smith::Update.compare("0.5.0", "v0.4.0").should eq(Smith::Update::Comparison::Ahead)
  end

  it "reports a malformed tag as incomparable rather than treating it as 0.0.0" do
    Smith::Update.compare("0.4.0", "nightly").should eq(Smith::Update::Comparison::Unknown)
    Smith::Update.compare("wip", "v0.4.0").should eq(Smith::Update::Comparison::Unknown)
  end
end

describe "Smith::Update build channel" do
  it "accepts only the channel a release build stamps in" do
    Smith::Update.release_build?("release").should be_true
    Smith::Update.release_build?("dev").should be_false
    Smith::Update.release_build?("").should be_false
    Smith::Update.release_build?("Release").should be_false
  end

  it "names the two kinds of build" do
    Smith::Update.describe_channel("release").should eq("release build")
    Smith::Update.describe_channel("dev").should eq("dev build")
  end
end

describe Smith::Update::Platform do
  # Driven with injected values: CI runs this on both ubuntu and macOS, so
  # asserting on the host would assert on the runner.
  it "maps the three targets release.yml builds" do
    Smith::Update::Platform.target?("linux", "x86_64").should eq("linux-x86_64")
    Smith::Update::Platform.target?("darwin", "arm64").should eq("darwin-arm64")
    Smith::Update::Platform.target?("darwin", "x86_64").should eq("darwin-x86_64")
  end

  it "accepts the usual spellings of the same machine" do
    Smith::Update::Platform.target?("Linux", "amd64").should eq("linux-x86_64")
    Smith::Update::Platform.target?("macos", "aarch64").should eq("darwin-arm64")
    Smith::Update::Platform.target?("Darwin", "X64").should eq("darwin-x86_64")
  end

  it "refuses a platform no release is built for" do
    Smith::Update::Platform.target?("linux", "arm64").should be_nil
    Smith::Update::Platform.target?("windows", "x86_64").should be_nil
    Smith::Update::Platform.target?("freebsd", "x86_64").should be_nil
    Smith::Update::Platform.target?("linux", "riscv64").should be_nil
  end
end

describe "Smith::Update.archive_name" do
  it "names the asset the way release.yml packs it" do
    Smith::Update.archive_name("v0.5.0", "darwin-arm64").should eq("smith-v0.5.0-darwin-arm64.tar.gz")
  end
end

describe Smith::Update::Release do
  it "reads tag and assets out of the GitHub answer" do
    body = <<-JSON
      {
        "tag_name": "v0.5.0",
        "assets": [
          {"name": "smith-v0.5.0-linux-x86_64.tar.gz", "browser_download_url": "https://github.com/webmatze/smith/releases/download/v0.5.0/smith-v0.5.0-linux-x86_64.tar.gz"},
          {"name": "SHA256SUMS", "browser_download_url": "https://github.com/webmatze/smith/releases/download/v0.5.0/SHA256SUMS"}
        ]
      }
      JSON

    release = Smith::Update::Release.from_json?(body).should_not be_nil
    release.tag.should eq("v0.5.0")
    release.assets.size.should eq(2)
    release.asset?("SHA256SUMS").not_nil!.url.should end_with("/SHA256SUMS")
    release.asset?("nothing-like-this").should be_nil
  end

  it "returns nil for a body that is not a release" do
    Smith::Update::Release.from_json?("not json at all").should be_nil
    Smith::Update::Release.from_json?(%({"message": "Not Found"})).should be_nil
    Smith::Update::Release.from_json?(%({"tag_name": ""})).should be_nil
  end

  it "returns nil for valid JSON that is not an object, instead of raising" do
    # JSON::Any#[]? raises on anything but a Hash, and the API answer is the
    # one input here that an attacker would shape.
    Smith::Update::Release.from_json?("[1,2]").should be_nil
    Smith::Update::Release.from_json?(%("a string")).should be_nil
    Smith::Update::Release.from_json?("42").should be_nil
    Smith::Update::Release.from_json?("null").should be_nil
    Smith::Update::Release.from_json?("true").should be_nil
  end

  it "skips assets that are not objects, instead of raising" do
    release = Smith::Update::Release.from_json?(%({"tag_name": "v1.0.0", "assets": [1, "x", null, []]}))
    release.not_nil!.tag.should eq("v1.0.0")
    release.not_nil!.assets.should be_empty
  end

  it "returns nil when assets is not an array at all" do
    release = Smith::Update::Release.from_json?(%({"tag_name": "v1.0.0", "assets": "nope"}))
    release.not_nil!.assets.should be_empty
  end

  it "skips assets missing a name or a URL rather than failing" do
    release = Smith::Update::Release.from_json?(%({"tag_name": "v1.0.0", "assets": [{"name": "x"}, {"browser_download_url": "https://x/y"}]}))
    release.not_nil!.assets.should be_empty
  end
end

describe Smith::Update::Checksums do
  it "parses sha256sum output, binary marker and all" do
    digest_a = "0" * 64
    digest_b = "1" * 64
    sums = Smith::Update::Checksums.parse(<<-SUMS)
      #{digest_a}  smith-v0.5.0-linux-x86_64.tar.gz
      #{digest_b} *smith-v0.5.0-darwin-arm64.tar.gz
      # a comment nobody promised would not be here
      garbage
      SUMS

    sums.size.should eq(2)
    sums["smith-v0.5.0-linux-x86_64.tar.gz"].should eq(digest_a)
    sums["smith-v0.5.0-darwin-arm64.tar.gz"].should eq(digest_b)
  end

  it "matches on the bare name even when the sums file carries a directory" do
    digest = "a" * 64
    sums = Smith::Update::Checksums.parse("#{digest}  dist/smith-v0.5.0-linux-x86_64.tar.gz\n")
    sums["smith-v0.5.0-linux-x86_64.tar.gz"].should eq(digest)
  end

  it "accepts a matching digest whatever its case" do
    sums = {"a.tar.gz" => "ab" * 32}
    Smith::Update::Checksums.verify(sums, "a.tar.gz", ("AB" * 32)).should be_nil
  end

  it "reports a mismatch and an entry that is not there at all" do
    sums = {"a.tar.gz" => "ab" * 32}
    Smith::Update::Checksums.verify(sums, "a.tar.gz", "cd" * 32).not_nil!.should contain("checksum mismatch")
    Smith::Update::Checksums.verify(sums, "b.tar.gz", "ab" * 32).not_nil!.should contain("not listed")
  end
end

describe "Smith::Update.classify" do
  it "recognises a Homebrew install through the Cellar the link points into" do
    Smith::Update.classify("/opt/homebrew/Cellar/smith/0.4.0/bin/smith", dir_writable: true).should eq(Smith::Update::Install::Homebrew)
    Smith::Update.classify("/usr/local/Cellar/smith/0.4.0/bin/smith", dir_writable: true).should eq(Smith::Update::Install::Homebrew)
    Smith::Update.classify("/opt/homebrew/bin/smith", dir_writable: true).should eq(Smith::Update::Install::Homebrew)
    Smith::Update.classify("/home/linuxbrew/.linuxbrew/bin/smith", dir_writable: true).should eq(Smith::Update::Install::Homebrew)
  end

  it "uses HOMEBREW_PREFIX when brew sits somewhere unusual" do
    Smith::Update.classify("/srv/brew/Cellar/smith/0.4.0/bin/smith", dir_writable: true, homebrew_prefix: "/srv/brew")
      .should eq(Smith::Update::Install::Homebrew)
    Smith::Update.classify("/srv/elsewhere/bin/smith", dir_writable: true, homebrew_prefix: "/srv/brew")
      .should eq(Smith::Update::Install::SelfManaged)
  end

  it "recognises the Nix store and the distribution's own directories" do
    Smith::Update.classify("/nix/store/abc-smith-0.4.0/bin/smith", dir_writable: true).should eq(Smith::Update::Install::Nix)
    Smith::Update.classify("/usr/bin/smith", dir_writable: true).should eq(Smith::Update::Install::SystemPath)
    Smith::Update.classify("/bin/smith", dir_writable: true).should eq(Smith::Update::Install::SystemPath)
  end

  it "refuses a directory the current user cannot write" do
    Smith::Update.classify("/opt/smith/bin/smith", dir_writable: false).should eq(Smith::Update::Install::ReadOnly)
  end

  it "leaves a hand-placed binary alone" do
    Smith::Update.classify("/home/me/.local/bin/smith", dir_writable: true).should eq(Smith::Update::Install::SelfManaged)
    # /usr/local is for exactly the hand-placed binaries this command exists for.
    Smith::Update.classify("/usr/local/bin/smith", dir_writable: true).should eq(Smith::Update::Install::SelfManaged)
  end

  it "names the package manager to use instead" do
    Smith::Update.advice(Smith::Update::Install::Homebrew, "/opt/homebrew/bin/smith").should contain("brew upgrade smith")
    Smith::Update.advice(Smith::Update::Install::Nix, "/nix/store/x/bin/smith").should contain("Nix store")
    Smith::Update.advice(Smith::Update::Install::SystemPath, "/usr/bin/smith").should contain("package manager")
    Smith::Update.advice(Smith::Update::Install::ReadOnly, "/opt/smith/bin/smith").should contain("not writable")
  end
end

describe "Smith::Update.download_reason" do
  it "passes an https URL" do
    Smith::Update.download_reason("https://github.com/webmatze/smith/releases/download/v1/a.tar.gz").should be_nil
  end

  it "refuses http rather than upgrading it, unlike a URL a human typed" do
    Smith::Update.download_reason("http://github.com/a.tar.gz").not_nil!.should contain("https only")
  end

  it "refuses every other scheme and a URL with no host" do
    Smith::Update.download_reason("file:///etc/passwd").not_nil!.should contain("https only")
    Smith::Update.download_reason("ftp://example.com/a").not_nil!.should contain("https only")
    Smith::Update.download_reason("/just/a/path").not_nil!.should contain("https only")
    Smith::Update.download_reason("https:///no-host").not_nil!.should contain("no host")
  end

  it "passes the hosts a release is actually served from" do
    Smith::Update.download_reason("https://api.github.com/repos/webmatze/smith/releases/latest").should be_nil
    Smith::Update.download_reason("https://objects.githubusercontent.com/x").should be_nil
    Smith::Update.download_reason("https://release-assets.githubusercontent.com/x").should be_nil
    Smith::Update.download_reason("https://GitHub.com/x").should be_nil
  end

  it "refuses a host outside the allow-list, however public and resolvable" do
    # The URL comes out of the API answer, so the address check cannot cover
    # this case — only pinning the host can.
    Smith::Update.download_reason("https://example.com/smith.tar.gz").not_nil!.should contain("only from")
    Smith::Update.download_reason("https://github.com.evil.test/x").not_nil!.should contain("only from")
    # The leading dot in the suffix is what makes this one a refusal.
    Smith::Update.download_reason("https://evilgithubusercontent.com/x").not_nil!.should contain("only from")
  end
end

describe "Smith::Update.redirect_target" do
  # The hop policy without a server: the loop resolves the Location, then puts
  # the result back through download_reason. Both halves are driven here.
  it "resolves a relative Location against the URL it came from" do
    target = Smith::Update.redirect_target("https://github.com/webmatze/smith/releases/download/v1/a.tar.gz", "/elsewhere/b.tar.gz")
    target.should eq("https://github.com/elsewhere/b.tar.gz")
    Smith::Update.download_reason(target).should be_nil
  end

  it "resolves the cross-host hop a release download depends on" do
    target = Smith::Update.redirect_target("https://github.com/x", "https://objects.githubusercontent.com/y")
    Smith::Update.download_reason(target).should be_nil
  end

  it "produces a URL the policy then refuses, for every hop worth refusing" do
    downgrade = Smith::Update.redirect_target("https://github.com/x", "http://github.com/y")
    Smith::Update.download_reason(downgrade).not_nil!.should contain("https only")

    offsite = Smith::Update.redirect_target("https://github.com/x", "https://evil.example.com/y")
    Smith::Update.download_reason(offsite).not_nil!.should contain("only from")

    metadata = Smith::Update.redirect_target("https://github.com/x", "https://169.254.169.254/latest/meta-data/")
    Smith::Update.download_reason(metadata).not_nil!.should contain("only from")
  end
end

describe Smith::Update::GitHubSource do
  # These reach the real class, and none of them opens a socket: the URL policy
  # is applied before any connection is attempted.
  it "refuses to fetch a non-https asset URL without connecting" do
    expect_raises(Smith::Update::Error, /https only/) do
      Smith::Update::GitHubSource.new.fetch(
        Smith::Update::Asset.new("a.tar.gz", "http://github.com/a.tar.gz"), Smith::Update::MAX_ARCHIVE
      )
    end
  end

  it "refuses to fetch an asset URL pointing off the allowed hosts" do
    expect_raises(Smith::Update::Error, /only from/) do
      Smith::Update::GitHubSource.new.fetch(
        Smith::Update::Asset.new("a.tar.gz", "https://evil.example.com/a.tar.gz"), Smith::Update::MAX_ARCHIVE
      )
    end
  end
end

describe Smith::Update::Installer do
  it "replaces the target by rename, leaving it executable and runnable" do
    with_temp_dir do |dir|
      target = File.join(dir, "smith")
      File.write(target, "the old binary")
      File.chmod(target, 0o755)

      Smith::Update::Installer.new(target).install(build_archive(dir, "#!/bin/sh\necho new\n"))

      File.read(target).should eq("#!/bin/sh\necho new\n")
      File.info(target).permissions.value.should eq(0o755)
      Dir.children(dir).none?(&.starts_with?(".smith-update")).should be_true
    end
  end

  it "refuses an archive without a smith binary and leaves the target alone" do
    with_temp_dir do |dir|
      target = File.join(dir, "smith")
      File.write(target, "the old binary")

      staging = File.join(dir, "wrong")
      FileUtils.mkdir_p(staging)
      File.write(File.join(staging, "other"), "x")
      archive = File.join(dir, "wrong.tar.gz")
      Process.run("tar", ["-czf", archive, "-C", staging, "other"])

      expect_raises(Smith::Update::Error) do
        Smith::Update::Installer.new(target).install(File.read(archive).to_slice)
      end

      File.read(target).should eq("the old binary")
      Dir.children(dir).none?(&.starts_with?(".smith-update")).should be_true
    end
  end

  # Chmod'ed and renamed *through* the link otherwise: 0755 onto whatever it
  # points at, anywhere on the filesystem, and a link where the binary was.
  it "refuses a smith member that is a symlink, touching nothing outside the staging directory" do
    with_temp_dir do |dir|
      victim = File.join(dir, "id_ed25519")
      File.write(victim, "secret key material")
      File.chmod(victim, 0o600)

      target = File.join(dir, "smith")
      File.write(target, "the real binary")
      File.chmod(target, 0o755)

      expect_raises(Smith::Update::Error, /not a regular file/) do
        Smith::Update::Installer.new(target).install(File.read(symlink_archive(dir, victim, "smith")).to_slice)
      end

      File.info(victim).permissions.value.should eq(0o600)
      File.read(victim).should eq("secret key material")
      File.symlink?(target).should be_false
      File.read(target).should eq("the real binary")
      Dir.children(dir).none?(&.starts_with?(".smith-update")).should be_true
    end
  end

  # Stored as "./smith" the two tars disagree: bsdtar normalises the prefix and
  # extracts it, so the regular-file check catches it, while GNU tar does not
  # match it against the requested member and unpacks nothing at all. Both fail
  # closed, so the assertion is on the outcome rather than on either message.
  it "refuses a ./smith member that is a symlink, whichever tar is installed" do
    with_temp_dir do |dir|
      victim = File.join(dir, "id_ed25519")
      File.write(victim, "secret key material")
      File.chmod(victim, 0o600)

      target = File.join(dir, "smith")
      File.write(target, "the real binary")
      File.chmod(target, 0o755)

      expect_raises(Smith::Update::Error) do
        Smith::Update::Installer.new(target).install(File.read(symlink_archive(dir, victim, "./smith")).to_slice)
      end

      File.info(victim).permissions.value.should eq(0o600)
      File.read(victim).should eq("secret key material")
      File.symlink?(target).should be_false
      File.read(target).should eq("the real binary")
      Dir.children(dir).none?(&.starts_with?(".smith-update")).should be_true
    end
  end

  it "sweeps a staging directory a killed run left behind, and spares a fresh one" do
    with_temp_dir do |dir|
      target = File.join(dir, "smith")
      File.write(target, "the old binary")

      stale = File.join(dir, ".smith-update-deadbee")
      FileUtils.mkdir_p(stale)
      File.write(File.join(stale, "archive.tar.gz"), "junk")
      File.touch(stale, Time.utc - 3.hours)

      fresh = File.join(dir, ".smith-update-livedog")
      FileUtils.mkdir_p(fresh)

      Smith::Update::Installer.new(target).install(build_archive(dir, "new\n"))

      Dir.exists?(stale).should be_false
      Dir.exists?(fresh).should be_true
      File.read(target).should eq("new\n")
    end
  end
end

describe Smith::Update::Command do
  it "refuses to update a dev build, before it goes anywhere near the network" do
    with_temp_dir do |dir|
      target = File.join(dir, "smith")
      File.write(target, "the dev binary")

      stdout = IO::Memory.new
      err = IO::Memory.new
      # A source that raises on any call: the refusal has to happen first.
      code = Smith::Update::Command.new(
        source: FailingSource.new, channel: "dev", current: "0.4.0", target: target, io: stdout, err: err
      ).run

      code.should eq(1)
      err.to_s.should contain("dev build")
      err.to_s.should contain("crystal build src/smith.cr")
      File.read(target).should eq("the dev binary")
    end
  end

  it "refuses a Homebrew install and names brew instead" do
    stdout = IO::Memory.new
    err = IO::Memory.new
    code = Smith::Update::Command.new(
      source: FailingSource.new, channel: "release", current: "0.4.0",
      target: "/opt/homebrew/Cellar/smith/0.4.0/bin/smith", io: stdout, err: err
    ).run

    code.should eq(1)
    err.to_s.should contain("brew upgrade smith")
  end

  it "does nothing when the newest release is the version already running" do
    with_temp_dir do |dir|
      target = File.join(dir, "smith")
      File.write(target, "unchanged")

      stdout = IO::Memory.new
      code = Smith::Update::Command.new(
        source: FakeSource.new(Smith::Update::Release.new("v0.4.0")),
        channel: "release", current: "0.4.0", target: target, io: stdout, err: IO::Memory.new
      ).run

      code.should eq(0)
      stdout.to_s.should contain("already the newest release")
      File.read(target).should eq("unchanged")
    end
  end

  it "does not update backwards when the build is ahead of the newest release" do
    with_temp_dir do |dir|
      target = File.join(dir, "smith")
      File.write(target, "unchanged")

      stdout = IO::Memory.new
      code = Smith::Update::Command.new(
        source: FakeSource.new(Smith::Update::Release.new("v0.4.0")),
        channel: "release", current: "0.9.0", target: target, io: stdout, err: IO::Memory.new
      ).run

      code.should eq(0)
      stdout.to_s.should contain("newer than the newest release")
      File.read(target).should eq("unchanged")
    end
  end

  it "refuses a release tag it cannot compare against" do
    with_temp_dir do |dir|
      target = File.join(dir, "smith")
      File.write(target, "unchanged")

      err = IO::Memory.new
      code = Smith::Update::Command.new(
        source: FakeSource.new(Smith::Update::Release.new("nightly")),
        channel: "release", current: "0.4.0", target: target, io: IO::Memory.new, err: err
      ).run

      code.should eq(1)
      err.to_s.should contain("cannot compare")
      File.read(target).should eq("unchanged")
    end
  end

  it "verifies the checksum and replaces the binary" do
    with_temp_dir do |dir|
      target = File.join(dir, "smith")
      File.write(target, "the old binary")
      File.chmod(target, 0o755)

      host = Smith::Update::Platform.host_target?.not_nil!
      name = Smith::Update.archive_name("v0.5.0", host)
      archive = build_archive(dir, "#!/bin/sh\necho 0.5.0\n")
      sums = "#{Digest::SHA256.hexdigest(archive)}  #{name}\n"

      release = Smith::Update::Release.new("v0.5.0", [
        Smith::Update::Asset.new(name, "https://github.com/webmatze/smith/releases/download/v0.5.0/#{name}"),
        Smith::Update::Asset.new("SHA256SUMS", "https://github.com/webmatze/smith/releases/download/v0.5.0/SHA256SUMS"),
      ])
      source = FakeSource.new(release, {name => archive, "SHA256SUMS" => sums.to_slice})

      stdout = IO::Memory.new
      err = IO::Memory.new
      code = Smith::Update::Command.new(
        source: source, channel: "release", current: "0.4.0", target: target, io: stdout, err: err
      ).run

      code.should eq(0)
      stdout.to_s.should contain("SHA-256 matches")
      stdout.to_s.should contain("0.4.0 → v0.5.0")
      File.read(target).should eq("#!/bin/sh\necho 0.5.0\n")
      File.info(target).permissions.value.should eq(0o755)
      source.fetched.should eq([name, "SHA256SUMS"])
      # A checksum file has no business being read under the archive ceiling.
      source.caps[name].should eq(Smith::Update::MAX_ARCHIVE)
      source.caps["SHA256SUMS"].should eq(Smith::Update::MAX_METADATA)
    end
  end

  it "refuses a checksum mismatch and leaves the binary exactly as it was" do
    with_temp_dir do |dir|
      target = File.join(dir, "smith")
      File.write(target, "the old binary")

      host = Smith::Update::Platform.host_target?.not_nil!
      name = Smith::Update.archive_name("v0.5.0", host)
      archive = build_archive(dir, "#!/bin/sh\necho 0.5.0\n")

      release = Smith::Update::Release.new("v0.5.0", [
        Smith::Update::Asset.new(name, "https://github.com/webmatze/smith/releases/download/v0.5.0/#{name}"),
        Smith::Update::Asset.new("SHA256SUMS", "https://github.com/webmatze/smith/releases/download/v0.5.0/SHA256SUMS"),
      ])
      source = FakeSource.new(release, {name => archive, "SHA256SUMS" => "#{"9" * 64}  #{name}\n".to_slice})

      err = IO::Memory.new
      code = Smith::Update::Command.new(
        source: source, channel: "release", current: "0.4.0", target: target, io: IO::Memory.new, err: err
      ).run

      code.should eq(1)
      err.to_s.should contain("checksum mismatch")
      err.to_s.should contain("left untouched")
      File.read(target).should eq("the old binary")
      Dir.children(File.dirname(target)).none?(&.starts_with?(".smith-update")).should be_true
    end
  end

  # Every release from the one shipping this command onward carries sums, so a
  # release without them is a signal — omitting the asset is all it would take
  # to get a silent unverified install.
  it "refuses a release newer than v0.4.0 that carries no checksums" do
    with_temp_dir do |dir|
      target = File.join(dir, "smith")
      File.write(target, "the old binary")

      host = Smith::Update::Platform.host_target?.not_nil!
      name = Smith::Update.archive_name("v0.5.0", host)
      archive = build_archive(dir, "#!/bin/sh\necho 0.5.0\n")

      release = Smith::Update::Release.new("v0.5.0", [
        Smith::Update::Asset.new(name, "https://github.com/webmatze/smith/releases/download/v0.5.0/#{name}"),
      ])

      err = IO::Memory.new
      code = Smith::Update::Command.new(
        source: FakeSource.new(release, {name => archive}),
        channel: "release", current: "0.4.0", target: target, io: IO::Memory.new, err: err
      ).run

      code.should eq(1)
      err.to_s.should contain("carries no SHA256SUMS")
      err.to_s.should contain("--allow-unverified")
      File.read(target).should eq("the old binary")
    end
  end

  it "installs that same release when --allow-unverified is passed, still warning" do
    with_temp_dir do |dir|
      target = File.join(dir, "smith")
      File.write(target, "the old binary")

      host = Smith::Update::Platform.host_target?.not_nil!
      name = Smith::Update.archive_name("v0.5.0", host)
      archive = build_archive(dir, "#!/bin/sh\necho 0.5.0\n")

      release = Smith::Update::Release.new("v0.5.0", [
        Smith::Update::Asset.new(name, "https://github.com/webmatze/smith/releases/download/v0.5.0/#{name}"),
      ])

      err = IO::Memory.new
      code = Smith::Update::Command.new(
        allow_unverified: true, source: FakeSource.new(release, {name => archive}),
        channel: "release", current: "0.4.0", target: target, io: IO::Memory.new, err: err
      ).run

      code.should eq(0)
      err.to_s.should contain("cannot be verified")
      File.read(target).should eq("#!/bin/sh\necho 0.5.0\n")
    end
  end

  it "warns and installs a release at or below v0.4.0, which genuinely has no sums" do
    with_temp_dir do |dir|
      target = File.join(dir, "smith")
      File.write(target, "the old binary")

      host = Smith::Update::Platform.host_target?.not_nil!
      name = Smith::Update.archive_name("v0.4.0", host)
      archive = build_archive(dir, "#!/bin/sh\necho 0.4.0\n")

      release = Smith::Update::Release.new("v0.4.0", [
        Smith::Update::Asset.new(name, "https://github.com/webmatze/smith/releases/download/v0.4.0/#{name}"),
      ])

      err = IO::Memory.new
      code = Smith::Update::Command.new(
        source: FakeSource.new(release, {name => archive}),
        channel: "release", current: "0.3.0", target: target, io: IO::Memory.new, err: err
      ).run

      code.should eq(0)
      err.to_s.should contain("cannot be verified")
      File.read(target).should eq("#!/bin/sh\necho 0.4.0\n")
    end
  end

  it "reports a release with no asset for this platform instead of installing something else" do
    with_temp_dir do |dir|
      target = File.join(dir, "smith")
      File.write(target, "unchanged")

      release = Smith::Update::Release.new("v0.5.0", [
        Smith::Update::Asset.new("smith-v0.5.0-solaris-sparc.tar.gz", "https://example.com/x.tar.gz"),
      ])

      err = IO::Memory.new
      code = Smith::Update::Command.new(
        source: FakeSource.new(release), channel: "release", current: "0.4.0", target: target, io: IO::Memory.new, err: err
      ).run

      code.should eq(1)
      err.to_s.should contain("carries no smith-v0.5.0-")
      File.read(target).should eq("unchanged")
    end
  end

  it "--check reports the build kind and the newer version, and changes nothing" do
    with_temp_dir do |dir|
      target = File.join(dir, "smith")
      File.write(target, "unchanged")

      stdout = IO::Memory.new
      code = Smith::Update::Command.new(
        check_only: true, source: FakeSource.new(Smith::Update::Release.new("v0.5.0")),
        channel: "dev", current: "0.4.0", target: target, io: stdout, err: IO::Memory.new
      ).run

      code.should eq(0)
      stdout.to_s.should contain("dev build")
      stdout.to_s.should contain("v0.5.0 is available")
      # A dev build is told the version exists, not to run `smith update`.
      stdout.to_s.should_not contain("Run `smith update`")
      File.read(target).should eq("unchanged")
    end
  end

  it "--check on an up-to-date release build says so and suggests nothing" do
    with_temp_dir do |dir|
      target = File.join(dir, "smith")
      File.write(target, "unchanged")

      stdout = IO::Memory.new
      code = Smith::Update::Command.new(
        check_only: true, source: FakeSource.new(Smith::Update::Release.new("v0.4.0")),
        channel: "release", current: "0.4.0", target: target, io: stdout, err: IO::Memory.new
      ).run

      code.should eq(0)
      stdout.to_s.should contain("release build")
      stdout.to_s.should contain("up to date")
    end
  end

  it "--check does not tell a platform with no release binary to run smith update" do
    stdout = IO::Memory.new
    code = Smith::Update::Command.new(
      check_only: true, source: FakeSource.new(Smith::Update::Release.new("v0.5.0")),
      channel: "release", current: "0.4.0", target: "/home/me/.local/bin/smith",
      host_target: nil, io: stdout, err: IO::Memory.new
    ).run

    code.should eq(0)
    stdout.to_s.should contain("v0.5.0 is available")
    stdout.to_s.should contain("Releases carry no binary for")
    stdout.to_s.should_not contain("Run `smith update`")
  end

  it "refuses an update on a platform no release is built for" do
    with_temp_dir do |dir|
      target = File.join(dir, "smith")
      File.write(target, "unchanged")

      err = IO::Memory.new
      code = Smith::Update::Command.new(
        source: FailingSource.new, channel: "release", current: "0.4.0",
        target: target, host_target: nil, io: IO::Memory.new, err: err
      ).run

      code.should eq(1)
      err.to_s.should contain("releases carry no binary for")
      err.to_s.should contain("Build from source instead")
      File.read(target).should eq("unchanged")
    end
  end

  it "--check on a Homebrew install points at brew" do
    stdout = IO::Memory.new
    code = Smith::Update::Command.new(
      check_only: true, source: FakeSource.new(Smith::Update::Release.new("v0.5.0")),
      channel: "release", current: "0.4.0", target: "/opt/homebrew/Cellar/smith/0.4.0/bin/smith",
      io: stdout, err: IO::Memory.new
    ).run

    code.should eq(0)
    stdout.to_s.should contain("brew upgrade smith")
    stdout.to_s.should_not contain("Run `smith update`")
  end

  it "reports a failure to reach the API rather than raising" do
    stdout = IO::Memory.new
    err = IO::Memory.new
    code = Smith::Update::Command.new(
      check_only: true, source: FailingSource.new, channel: "release", current: "0.4.0",
      target: "/home/me/.local/bin/smith", io: stdout, err: err
    ).run

    code.should eq(1)
    err.to_s.should contain("could not reach api.github.com")
  end
end
