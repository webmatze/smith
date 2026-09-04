require "../spec_helper"
require "../support/marketplace_fixture"
require "../../src/smith/marketplace"

# Every spec here runs against a throwaway SMITH_HOME: the registry, the clone
# cache and the installed plugins all hang off Smith.home_dir, and none of them
# may ever be written into a developer's real ~/.smith.
private def with_home(&)
  temp_dir = File.join(Dir.tempdir, "smith_market_#{Random::Secure.hex(6)}")
  home = File.join(temp_dir, "smith-home")
  FileUtils.mkdir_p(home)

  previous = ENV["SMITH_HOME"]?
  ENV["SMITH_HOME"] = home
  begin
    yield temp_dir
  ensure
    previous ? (ENV["SMITH_HOME"] = previous) : ENV.delete("SMITH_HOME")
    remove_tree(temp_dir)
  end
end

# The fixture marketplace, plus a `run` that drives the subcommands the way the
# CLI does and hands back everything they printed.
private def with_fixture(&)
  with_home do |temp_dir|
    repo = MarketplaceFixture.build(File.join(temp_dir, "fixture"))
    yield temp_dir, repo
  end
end

private def run(*arguments : String) : String
  printed = IO::Memory.new
  Smith::Marketplace::Commands.new(printed).dispatch(arguments.to_a)
  printed.to_s
end

private def parse(json : String) : Smith::Marketplace::Manifest
  Smith::Marketplace::Manifest.parse(json)
end

describe Smith::Marketplace::Manifest do
  it "reads the required fields, pluginRoot and renames" do
    manifest = parse(<<-JSON)
      {
        "name": "my-plugins",
        "owner": {"name": "Someone"},
        "description": "…",
        "version": "1.0.0",
        "metadata": {"pluginRoot": "./packages"},
        "renames": {"old-name": "new-name", "gone": null},
        "plugins": [
          {"name": "new-name", "source": "./packages/new-name", "version": "1.2.3"}
        ]
      }
      JSON

    manifest.name.should eq("my-plugins")
    manifest.owner.should eq("Someone")
    manifest.plugin_root.should eq("./packages")
    manifest.renames["old-name"].should eq("new-name")
    manifest.renames["gone"].should be_nil
    manifest.plugins.size.should eq(1)
    manifest.plugins.first.version.should eq("1.2.3")
  end

  it "refuses a manifest without a name or without plugins" do
    expect_raises(Smith::Marketplace::Error, /no "name"/) do
      parse(%({"owner": {"name": "x"}, "plugins": []}))
    end

    expect_raises(Smith::Marketplace::Error, /no "plugins"/) do
      parse(%({"name": "x", "owner": {"name": "y"}}))
    end

    expect_raises(Smith::Marketplace::Error, /not valid JSON/) do
      parse("{ nope")
    end
  end

  it "keeps a marketplace name from becoming a path" do
    expect_raises(Smith::Marketplace::Error, /not a usable name/) do
      parse(%({"name": "../evil", "owner": {}, "plugins": []}))
    end
  end

  it "skips a plugin whose name could not be a directory, and says so" do
    manifest = parse(<<-JSON)
      {
        "name": "m", "owner": {"name": "o"},
        "plugins": [
          {"name": "../escape", "source": "./x"},
          {"name": "-rf", "source": "./y"},
          {"name": "fine", "source": "./z"}
        ]
      }
      JSON

    manifest.plugins.map(&.name).should eq(["fine"])
    manifest.warnings.size.should eq(2)
    manifest.warnings.first.should contain("cannot be a directory")
  end

  it "follows renames and refuses a withdrawn plugin" do
    manifest = parse(<<-JSON)
      {
        "name": "m", "owner": {"name": "o"},
        "renames": {"old": "new", "dropped": null},
        "plugins": [{"name": "new", "source": "./new"}]
      }
      JSON

    manifest.resolve("old").name.should eq("new")
    expect_raises(Smith::Marketplace::Error, /withdrawn/) { manifest.resolve("dropped") }
    expect_raises(Smith::Marketplace::Error, /has no plugin/) { manifest.resolve("absent") }
  end

  # Claude Code is explicit: "A source that contains a `/`, such as
  # `team-a/formatter`, isn't a bare name and still needs the `./` prefix, even
  # when `metadata.pluginRoot` is set."
  it "applies pluginRoot only to a name with no slash in it" do
    with_home do |temp_dir|
      root = File.join(temp_dir, "market")
      FileUtils.mkdir_p(File.join(root, "plugins", "good"))
      FileUtils.mkdir_p(File.join(root, "plugins", "bare"))

      manifest = parse(<<-JSON)
        {
          "name": "m", "owner": {"name": "o"},
          "metadata": {"pluginRoot": "./plugins"},
          "plugins": [
            {"name": "bare", "source": "bare"},
            {"name": "slashed", "source": "plugins/good"},
            {"name": "dotted", "source": "./plugins/good"}
          ]
        }
        JSON

      resolved = Smith::Marketplace.real_path(root)
      manifest.source_dir(root, manifest.resolve("bare")).should eq(File.join(resolved, "plugins", "bare"))
      # Not <root>/plugins/plugins/good, which failed to install at all.
      manifest.source_dir(root, manifest.resolve("slashed")).should eq(File.join(resolved, "plugins", "good"))
      manifest.source_dir(root, manifest.resolve("dotted")).should eq(File.join(resolved, "plugins", "good"))
    end
  end

  it "resolves a bare source name under pluginRoot and a written path from the root" do
    with_home do |temp_dir|
      root = File.join(temp_dir, "market")
      FileUtils.mkdir_p(File.join(root, "packages", "bare"))
      FileUtils.mkdir_p(File.join(root, "elsewhere"))

      manifest = parse(<<-JSON)
        {
          "name": "m", "owner": {"name": "o"},
          "metadata": {"pluginRoot": "packages"},
          "plugins": [
            {"name": "bare", "source": "bare"},
            {"name": "written", "source": "./elsewhere"}
          ]
        }
        JSON

      manifest.source_dir(root, manifest.resolve("bare")).should eq(File.join(Smith::Marketplace.real_path(root), "packages", "bare"))
      manifest.source_dir(root, manifest.resolve("written")).should eq(File.join(Smith::Marketplace.real_path(root), "elsewhere"))
    end
  end
end

describe Smith::Marketplace::Source do
  it "reads all four object source forms and the string form" do
    relative = Smith::Marketplace::Source.parse(JSON.parse(%("./plugins/foo")))
    relative.kind.relative?.should be_true
    relative.path.should eq("./plugins/foo")
    relative.supported?.should be_true

    github = Smith::Marketplace::Source.parse(JSON.parse(%({"source": "github", "repo": "acme/deploy", "ref": "v2.0.0", "sha": "a1b2c3d4"})))
    github.kind.git_hub?.should be_true
    github.repo.should eq("acme/deploy")
    github.ref.should eq("v2.0.0")
    github.sha.should eq("a1b2c3d4")
    github.supported?.should be_true

    url = Smith::Marketplace::Source.parse(JSON.parse(%({"source": "url", "url": "https://example.com/p.git", "ref": "main"})))
    url.kind.git_url?.should be_true
    url.supported?.should be_true

    subdir = Smith::Marketplace::Source.parse(JSON.parse(%({"source": "git-subdir", "url": "https://example.com/p.git", "path": "sub"})))
    subdir.kind.git_subdir?.should be_true
    subdir.supported?.should be_false
    subdir.refusal.not_nil!.should contain("Phase 2")
  end

  it "refuses npm and command sources with a reason, permanently" do
    npm = Smith::Marketplace::Source.parse(JSON.parse(%({"source": "npm", "package": "@acme/x"})))
    npm.supported?.should be_false
    npm.refusal.not_nil!.should contain("package manager")

    command = Smith::Marketplace::Source.parse(JSON.parse(%({"source": "command", "command": "make plugin"})))
    command.supported?.should be_false
    command.refusal.not_nil!.should contain("code execution")
  end

  it "still parses a marketplace that holds a refused source" do
    # The whole point of parsing sources leniently: one npm entry must not cost
    # the marketplace its listing.
    manifest = parse(<<-JSON)
      {
        "name": "m", "owner": {"name": "o"},
        "plugins": [
          {"name": "good", "source": "./good"},
          {"name": "bad", "source": {"source": "npm", "package": "x"}}
        ]
      }
      JSON

    manifest.plugins.map(&.name).should eq(["good", "bad"])
  end
end

describe Smith::Marketplace do
  describe "path containment" do
    it "refuses a source that leaves the marketplace root" do
      with_home do |temp_dir|
        root = File.join(temp_dir, "market")
        FileUtils.mkdir_p(root)

        expect_raises(Smith::Marketplace::Error, /'\.\.'/) do
          Smith::Marketplace.resolve_within(root, "../../etc")
        end
        expect_raises(Smith::Marketplace::Error, /'\.\.'/) do
          Smith::Marketplace.resolve_within(root, "plugins/../../escape")
        end
        expect_raises(Smith::Marketplace::Error, /absolute/) do
          Smith::Marketplace.resolve_within(root, "/etc/passwd")
        end
        expect_raises(Smith::Marketplace::Error, /NUL/) do
          Smith::Marketplace.resolve_within(root, "plugins/\0/x")
        end
        expect_raises(Smith::Marketplace::Error, /empty/) do
          Smith::Marketplace.resolve_within(root, "")
        end
      end
    end

    it "refuses a source that is a symlink out of the tree" do
      with_home do |temp_dir|
        root = File.join(temp_dir, "market")
        outside = File.join(temp_dir, "outside")
        FileUtils.mkdir_p(root)
        FileUtils.mkdir_p(outside)
        File.symlink(outside, File.join(root, "escape"))

        expect_raises(Smith::Marketplace::Error, /symlink/) do
          Smith::Marketplace.resolve_within(root, "escape")
        end
      end
    end

    it "accepts an ordinary path below the root" do
      with_home do |temp_dir|
        root = File.join(temp_dir, "market")
        FileUtils.mkdir_p(File.join(root, "plugins", "foo"))

        resolved = Smith::Marketplace.resolve_within(root, "./plugins/foo")
        Smith::Marketplace.within?(Smith::Marketplace.real_path(root), resolved).should be_true
      end
    end

    it "keeps an install target inside the installed directory" do
      with_home do
        target = Smith::Marketplace.install_target("fixture", "demo")
        Smith::Marketplace.within?(File.expand_path(Smith::Marketplace.installed_dir), target).should be_true

        expect_raises(Smith::Marketplace::Error, /not a usable name/) do
          Smith::Marketplace.install_target("fixture", "../../escape")
        end
        expect_raises(Smith::Marketplace::Error, /not a usable name/) do
          Smith::Marketplace.install_target("..", "demo")
        end
        expect_raises(Smith::Marketplace::Error, /not a usable name/) do
          Smith::Marketplace.install_target("fixture", "-rf")
        end
        expect_raises(Smith::Marketplace::Error, /not a usable name/) do
          Smith::Marketplace.install_target("fixture", "/etc/passwd")
        end
      end
    end

    it "never follows a symlink while copying a plugin" do
      with_home do |temp_dir|
        source = File.join(temp_dir, "plugin")
        outside = File.join(temp_dir, "secrets")
        FileUtils.mkdir_p(File.join(source, "skills", "real"))
        FileUtils.mkdir_p(outside)
        File.write(File.join(outside, "id_rsa"), "very secret")
        File.write(File.join(source, "skills", "real", "SKILL.md"), "---\nname: real\ndescription: d\n---\nbody")
        File.symlink(outside, File.join(source, "stolen"))

        target = File.join(temp_dir, "copy")
        skipped = Array(String).new
        Smith::Marketplace.copy_tree(source, target, skipped)

        skipped.should eq(["stolen"])
        File.exists?(File.join(target, "skills", "real", "SKILL.md")).should be_true
        File.exists?(File.join(target, "stolen")).should be_false
      end
    end
  end

  describe "source arguments" do
    it "expands the owner/repo shorthand and accepts https urls" do
      Smith::Marketplace::Origin.parse("acme/plugins").url.should eq("https://github.com/acme/plugins")
      Smith::Marketplace::Origin.parse("acme/plugins@v1.2").ref.should eq("v1.2")

      https = Smith::Marketplace::Origin.parse("https://example.com/acme/plugins.git#main")
      https.url.should eq("https://example.com/acme/plugins.git")
      https.ref.should eq("main")
    end

    it "refuses ssh, git, file and ext urls" do
      ["git@github.com:acme/plugins.git",
       "ssh://git@example.com/p.git",
       "git://example.com/p.git",
       "file:///etc",
       "ext::sh -c whoami",
       "--upload-pack=touch /tmp/pwned"].each do |spec|
        expect_raises(Smith::Marketplace::Error) { Smith::Marketplace::Origin.parse(spec) }
      end
    end

    it "refuses a ref that could be read as a git flag" do
      expect_raises(Smith::Marketplace::Error, /not a usable git ref/) do
        Smith::Marketplace::Safe.ref!("--upload-pack=touch /tmp/x")
      end
      expect_raises(Smith::Marketplace::Error, /not a usable git ref/) do
        Smith::Marketplace::Safe.ref!("main;rm -rf /")
      end
      expect_raises(Smith::Marketplace::Error, /not a usable git ref/) do
        Smith::Marketplace::Safe.ref!("refs/heads/../evil")
      end
      Smith::Marketplace::Safe.ref!("refs/tags/v1.0.0").should eq("refs/tags/v1.0.0")
    end
  end

  describe "registry" do
    it "replaces the entry when the same marketplace name is added twice" do
      with_fixture do |temp_dir, repo|
        run("marketplace", "add", repo.bare)
        first = Smith::Marketplace::Registry.load
        first.names.should eq(["fixture"])

        # The same marketplace, added from the working tree this time: one name,
        # one entry, the newer source.
        run("marketplace", "add", repo.work)
        second = Smith::Marketplace::Registry.load
        second.names.should eq(["fixture"])
        second["fixture"].source.should eq(repo.work)
        second["fixture"].local?.should be_true
      end
    end

    it "removes the plugins installed from a marketplace along with it" do
      with_fixture do |temp_dir, repo|
        run("marketplace", "add", repo.work)
        run("install", "skills-demo@fixture")
        run("install", "root-skill@fixture")
        Smith::Marketplace.installed.map(&.plugin).should eq(["root-skill", "skills-demo"])

        output = run("marketplace", "remove", "fixture")
        output.should contain("Also uninstalled 2 plugins")
        Smith::Marketplace.installed.should be_empty
        Smith::Marketplace::Registry.load.empty?.should be_true
        Dir.exists?(File.join(Smith::Marketplace.installed_dir, "fixture")).should be_false
      end
    end

    it "survives a directory under installed/ that cannot be listed" do
      with_home do |temp_dir|
        plugin = File.join(Smith::Marketplace.installed_dir, "mkt", "plug", "skills", "s")
        FileUtils.mkdir_p(plugin)
        File.write(File.join(plugin, "SKILL.md"), "---\nname: s\ndescription: d\n---\nbody")

        unreadable = File.join(Smith::Marketplace.installed_dir, "mkt")
        File.chmod(unreadable, 0o000)

        begin
          # `smith plugin uninstall` is among the commands this would take down,
          # which is the one that would repair it.
          Smith::Marketplace.installed.should be_empty

          catalog = Smith::Skills::Catalog.discover(workspace_dir: temp_dir, warn_io: IO::Memory.new)
          catalog.skills.should be_empty
          catalog.warnings.join("\n").should contain("could not be listed")

          agents = IO::Memory.new
          Smith::Agents::Catalog.discover(workspace_dir: temp_dir, warn_io: agents).agents.should be_empty
        ensure
          File.chmod(unreadable, 0o755)
        end
      end
    end

    it "drops a registry entry whose url or ref could not be added today" do
      with_home do
        FileUtils.mkdir_p(Smith::Marketplace.root_dir)
        File.write(Smith::Marketplace.registry_path, <<-JSON)
          {"version": 1, "marketplaces": {
            "sshy": {"name": "sshy", "source": "x", "url": "ssh://evil/repo.git", "added_at": "t", "updated_at": "t"},
            "exty": {"name": "exty", "source": "x", "url": "ext::sh -c whoami", "added_at": "t", "updated_at": "t"},
            "flaggy": {"name": "flaggy", "source": "x", "url": "https://example.com/r.git", "ref": "--upload-pack=touch /tmp/x", "added_at": "t", "updated_at": "t"},
            "relative": {"name": "relative", "source": "x", "dir": "../elsewhere", "added_at": "t", "updated_at": "t"},
            "fine": {"name": "fine", "source": "x", "url": "https://example.com/r.git", "ref": "v1.0.0", "added_at": "t", "updated_at": "t"}
          }}
          JSON

        # The url and the ref reach a git command line; the file is editable, so
        # they are validated coming back in and not only going out.
        Smith::Marketplace::Registry.load.names.should eq(["fine"])
      end
    end

    it "drops a registry entry whose name could be a path" do
      with_home do
        FileUtils.mkdir_p(Smith::Marketplace.root_dir)
        File.write(Smith::Marketplace.registry_path, <<-JSON)
          {"version": 1, "marketplaces": {
            "../escape": {"name": "../escape", "source": "x", "added_at": "t", "updated_at": "t"},
            "renamed": {"name": "something-else", "source": "x", "added_at": "t", "updated_at": "t"},
            "fine": {"name": "fine", "source": "x", "added_at": "t", "updated_at": "t"}
          }}
          JSON

        # `marketplace remove` deletes a directory named after the key, so a
        # hand-edited file must not be able to name one outside ~/.smith.
        Smith::Marketplace::Registry.load.names.should eq(["fine"])
      end
    end

    it "names the marketplaces it knows when asked for one it does not" do
      with_fixture do |temp_dir, repo|
        run("marketplace", "add", repo.work)

        expect_raises(Smith::Marketplace::Error, /Registered: fixture/) do
          run("install", "skills-demo@nope")
        end
      end
    end
  end

  describe "git, against a local bare repository" do
    it "adds, lists and then sees a new commit on update" do
      with_fixture do |temp_dir, repo|
        added = run("marketplace", "add", repo.bare)
        added.should contain("Added marketplace 'fixture'")
        added.should contain("7 plugins")

        entry = Smith::Marketplace::Registry.load["fixture"]
        entry.commit.should eq(MarketplaceFixture.head(repo.work))
        entry.local?.should be_false
        Dir.exists?(File.join(Smith::Marketplace.cache_dir, "fixture")).should be_true

        listing = run("marketplace", "list")
        listing.should contain("fixture")
        listing.should contain(entry.commit.not_nil![0, 8])

        run("marketplace", "update").should contain("up to date")

        moved = MarketplaceFixture.advance(repo)
        updated = run("marketplace", "update")
        updated.should contain("→ #{moved[0, 8]}")
        Smith::Marketplace::Registry.load["fixture"].commit.should eq(moved)
      end
    end

    # The pin is the whole point of a pin: a marketplace names an audited
    # commit, the upstream is force-pushed or taken over, and the pinned commit
    # stops being reachable. Falling back to whatever the remote calls HEAD
    # today would install the attacker's tree, record it as the version, and
    # report "up to date" ever after.
    it "refuses a pinned sha the repository does not contain" do
      with_fixture do |temp_dir, repo|
        dest = File.join(temp_dir, "pinned")

        expect_raises(Smith::Marketplace::Error, /does not contain the pinned commit/) do
          Smith::Marketplace::Git.materialize(repo.bare, dest, sha: "0123456789abcdef0123456789abcdef01234567")
        end
      end
    end

    it "refuses a pinned ref the repository does not contain" do
      with_fixture do |temp_dir, repo|
        dest = File.join(temp_dir, "pinned-ref")

        expect_raises(Smith::Marketplace::Error, /does not contain the pinned ref/) do
          Smith::Marketplace::Git.materialize(repo.bare, dest, ref: "v9-does-not-exist")
        end
      end
    end

    it "resolves a pin the repository does contain" do
      with_fixture do |temp_dir, repo|
        head = MarketplaceFixture.head(repo.work)

        Smith::Marketplace::Git.materialize(repo.bare, File.join(temp_dir, "by-sha"), sha: head).should eq(head)
        Smith::Marketplace::Git.materialize(repo.bare, File.join(temp_dir, "by-ref"), ref: "main").should eq(head)
        Smith::Marketplace::Git.materialize(repo.bare, File.join(temp_dir, "by-head")).should eq(head)
      end
    end

    it "still resolves a pin when only a full fetch can serve it" do
      with_fixture do |temp_dir, repo|
        first = MarketplaceFixture.head(repo.work)
        MarketplaceFixture.advance(repo, "move past the pin")

        # The older commit is no longer any ref's tip, so a shallow fetch of it
        # is the case that drives the full-fetch fallback — the path where
        # FETCH_HEAD is the default branch and the pin has to be named.
        dest = File.join(temp_dir, "older")
        Smith::Marketplace::Git.materialize(repo.bare, dest, sha: first).should eq(first)
      end
    end

    it "leaves no staging directory behind" do
      with_fixture do |temp_dir, repo|
        run("marketplace", "add", repo.bare)
        Dir.children(Smith::Marketplace.cache_dir).should eq(["fixture"])
      end
    end
  end

  describe "install" do
    it "installs a plugin with a skills/ directory" do
      with_fixture do |temp_dir, repo|
        run("marketplace", "add", repo.work)
        output = run("install", "skills-demo@fixture")

        output.should contain("Installed skills-demo@fixture 1.2.0")
        output.should contain("skills-demo:alpha, skills-demo:deploy")
        output.should contain("agents:  (none)")

        target = File.join(Smith::Marketplace.installed_dir, "fixture", "skills-demo")
        File.exists?(File.join(target, "skills", "alpha", "SKILL.md")).should be_true

        meta = Smith::Marketplace::InstallMeta.load(target).not_nil!
        meta.version.should eq("1.2.0")
        meta.marketplace.should eq("fixture")
        meta.ignored.should be_empty
      end
    end

    it "installs a plugin whose only skill is a root SKILL.md" do
      with_fixture do |temp_dir, repo|
        run("marketplace", "add", repo.work)
        run("install", "root-skill@fixture").should contain("skills:  root-skill:summarise")
      end
    end

    it "installs a plugin of agent definitions" do
      with_fixture do |temp_dir, repo|
        run("marketplace", "add", repo.work)
        output = run("install", "agents-demo@fixture")

        output.should contain("agents:  agents-demo:auditor")
        output.should contain("skills:  (none)")
        # No plugin.json, so the marketplace entry's version decides.
        Smith::Marketplace::InstallMeta.load(File.join(Smith::Marketplace.installed_dir, "fixture", "agents-demo")).not_nil!.version.should eq("2.0.0")
      end
    end

    it "says what a plugin's own definitions declare, at install time" do
      with_fixture do |temp_dir, repo|
        run("marketplace", "add", repo.work)
        output = run("install", "agents-demo@fixture")

        # The fixture's auditor carries `maxTurns` and `isolation`. Said here,
        # where the reader is deciding about this plugin — and, from this
        # release on, nowhere near the startup path of every later command.
        output.should contain("1 note about what this plugin declares")
        output.should contain("smith does not act on isolation, maxTurns")
      end
    end

    it "names the components it will not load, loudly" do
      with_fixture do |temp_dir, repo|
        run("marketplace", "add", repo.work)
        output = run("install", "hooky@fixture")

        output.should contain("Not loaded from this plugin")
        %w[hooks mcpServers lspServers].each { |component| output.should contain(component) }
        output.should contain("hooky:gate")

        meta = Smith::Marketplace::InstallMeta.load(File.join(Smith::Marketplace.installed_dir, "fixture", "hooky")).not_nil!
        meta.ignored.should contain("hooks")
        meta.ignored.should contain("mcpServers")

        run("list").should contain("ignored:")
      end
    end

    it "refuses an npm source and a git-subdir source with a reason" do
      with_fixture do |temp_dir, repo|
        run("marketplace", "add", repo.work)

        expect_raises(Smith::Marketplace::Error, /package manager/) { run("install", "npm-demo@fixture") }
        expect_raises(Smith::Marketplace::Error, /Phase 2/) { run("install", "subdir-demo@fixture") }
        Smith::Marketplace.installed.should be_empty
      end
    end

    it "refuses a source that points outside the marketplace" do
      with_fixture do |temp_dir, repo|
        run("marketplace", "add", repo.work)

        expect_raises(Smith::Marketplace::Error, /'\.\.'/) { run("install", "escape-demo@fixture") }
        Smith::Marketplace.installed.should be_empty
      end
    end

    # An install is a long copy, and anything can end it: Ctrl-C, a full disk,
    # a file the plugin will not let smith read. What must never happen is a
    # half-plugin going live — or an interrupted re-install destroying the
    # working plugin it was replacing.
    it "leaves nothing behind when the copy cannot finish" do
      with_fixture do |temp_dir, repo|
        MarketplaceFixture.write(repo.work, "plugins/half/skills/ok/SKILL.md", "---\nname: ok\ndescription: d\n---\nbody")
        MarketplaceFixture.write(repo.work, "plugins/half/unreadable", "secret")
        File.chmod(File.join(repo.work, "plugins", "half", "unreadable"), 0o000)
        MarketplaceFixture.write(repo.work, ".claude-plugin/marketplace.json",
          %({"name": "fixture", "owner": {"name": "o"}, "plugins": [{"name": "half", "source": "./plugins/half"}]}))

        run("marketplace", "add", repo.work)
        expect_raises(Smith::Marketplace::Error, /could not copy unreadable/) { run("install", "half@fixture") }

        Smith::Marketplace.installed.should be_empty
        Smith::Skills::Catalog.discover(workspace_dir: temp_dir, warn_io: IO::Memory.new).skills.should be_empty
        # Not even under its staging name.
        marketplace_dir = File.join(Smith::Marketplace.installed_dir, "fixture")
        (Dir.exists?(marketplace_dir) ? Dir.children(marketplace_dir) : Array(String).new).should be_empty
      end
    end

    it "keeps the working plugin when a re-install cannot finish" do
      with_fixture do |temp_dir, repo|
        run("marketplace", "add", repo.work)
        run("install", "skills-demo@fixture")

        # The same plugin, now uncopyable.
        MarketplaceFixture.write(repo.work, "plugins/skills-demo/unreadable", "secret")
        File.chmod(File.join(repo.work, "plugins", "skills-demo", "unreadable"), 0o000)

        expect_raises(Smith::Marketplace::Error, /could not copy/) { run("install", "skills-demo@fixture") }

        # The copy that was already there is untouched.
        installed = Smith::Marketplace.installed
        installed.map(&.plugin).should eq(["skills-demo"])
        installed.first.meta.not_nil!.version.should eq("1.2.0")
        File.exists?(File.join(installed.first.dir, "skills", "alpha", "SKILL.md")).should be_true
      end
    end

    it "names the plugins it has when asked for one it has not" do
      with_fixture do |temp_dir, repo|
        run("marketplace", "add", repo.work)

        expect_raises(Smith::Marketplace::Error, /It lists: agents-demo/) do
          run("install", "absent@fixture")
        end
      end
    end

    it "insists on the plugin@marketplace form" do
      with_fixture do |temp_dir, repo|
        run("marketplace", "add", repo.work)

        expect_raises(Smith::Marketplace::Error, /<plugin>@<marketplace>/) { run("install", "skills-demo") }
      end
    end
  end

  describe "version resolution" do
    it "prefers plugin.json, then the marketplace entry, then the commit" do
      with_fixture do |temp_dir, repo|
        run("marketplace", "add", repo.bare)
        commit = Smith::Marketplace::Registry.load["fixture"].commit.not_nil!

        run("install", "skills-demo@fixture") # plugin.json says 1.2.0
        run("install", "agents-demo@fixture") # no plugin.json; the entry says 2.0.0
        run("install", "hooky@fixture")       # plugin.json says 3.0.0

        versions = Smith::Marketplace.installed.to_h { |p| {p.plugin, p.meta.not_nil!.version} }
        versions["skills-demo"].should eq("1.2.0")
        versions["agents-demo"].should eq("2.0.0")
        versions["hooky"].should eq("3.0.0")

        # A plugin with neither falls back to the resolved commit.
        MarketplaceFixture.write(repo.work, "plugins/plain/skills/only/SKILL.md", "---\nname: only\ndescription: d\n---\nbody")
        MarketplaceFixture.write(repo.work, ".claude-plugin/marketplace.json", <<-JSON)
          {"name": "fixture", "owner": {"name": "o"},
           "plugins": [{"name": "plain", "source": "./plugins/plain"}]}
          JSON
        moved = MarketplaceFixture.advance(repo, "add a plugin with no version")
        run("marketplace", "update")
        run("install", "plain@fixture")

        Smith::Marketplace.installed.find { |p| p.plugin == "plain" }.not_nil!.meta.not_nil!.version.should eq(moved)
        moved.should_not eq(commit)
      end
    end

    it "reports an unchanged version as up to date instead of copying again" do
      with_fixture do |temp_dir, repo|
        run("marketplace", "add", repo.work)
        run("install", "skills-demo@fixture")

        installed_at = Smith::Marketplace.installed.first.meta.not_nil!.installed_at
        run("update", "skills-demo").should contain("up to date at 1.2.0")
        Smith::Marketplace.installed.first.meta.not_nil!.installed_at.should eq(installed_at)
      end
    end

    it "copies again when the version moved" do
      with_fixture do |temp_dir, repo|
        run("marketplace", "add", repo.work)
        run("install", "skills-demo@fixture")

        MarketplaceFixture.write(repo.work, "plugins/skills-demo/.claude-plugin/plugin.json",
          %({"name": "skills-demo", "description": "Two skills", "version": "1.3.0"}))

        run("update", "skills-demo").should contain("1.2.0 → 1.3.0")
        Smith::Marketplace.installed.first.meta.not_nil!.version.should eq("1.3.0")
      end
    end
  end

  describe "uninstall and list" do
    it "uninstalls one plugin and leaves the rest" do
      with_fixture do |temp_dir, repo|
        run("marketplace", "add", repo.work)
        run("install", "skills-demo@fixture")
        run("install", "root-skill@fixture")

        run("uninstall", "skills-demo").should contain("Uninstalled skills-demo@fixture")
        Smith::Marketplace.installed.map(&.plugin).should eq(["root-skill"])

        expect_raises(Smith::Marketplace::Error, /no plugin "skills-demo" is installed/) do
          run("uninstall", "skills-demo")
        end
      end
    end

    it "lists nothing before anything is installed" do
      with_home do
        run("list").should contain("No plugins installed")
        run("marketplace", "list").should contain("No marketplaces registered")
      end
    end

    it "refuses an unknown subcommand rather than doing something else" do
      with_home do
        expect_raises(Smith::Marketplace::Error, /unknown 'smith plugin' subcommand/) { run("frobnicate") }
        expect_raises(Smith::Marketplace::Error, /unknown 'smith plugin marketplace' subcommand/) { run("marketplace", "frobnicate") }
      end
    end
  end
end
