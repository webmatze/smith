require "file_utils"

# A marketplace to test against, built on disk: a working tree plus a bare
# clone of it that stands in for a remote.
#
# Deliberately local. Every git path smith has is exercised against this — add,
# update, a new commit arriving — with no network involved, so the suite is the
# same on a laptop with no route out as it is in CI.
module MarketplaceFixture
  # A committer of our own: a CI runner has no user.name, and a developer may
  # have commit signing on, which would fail every commit made here.
  CONFIG = [
    "-c", "user.name=Smith Fixture",
    "-c", "user.email=fixture@example.invalid",
    "-c", "commit.gpgsign=false",
    "-c", "protocol.file.allow=always",
  ]

  record Repo, work : String, bare : String

  def self.git(arguments : Array(String), chdir : String? = nil) : String
    output = IO::Memory.new
    status = Process.run("git", CONFIG + arguments, chdir: chdir, output: output, error: output)
    raise "git #{arguments.join(" ")} failed: #{output}" unless status.success?
    output.to_s
  end

  # Writes the marketplace tree, commits it, and clones it bare.
  def self.build(base : String) : Repo
    work = File.join(base, "work")
    bare = File.join(base, "market.git")

    write_tree(work)

    git(["init", "-q"], chdir: work)
    # `init -b main` needs git 2.28; setting the symbolic ref works everywhere
    # and keeps the default branch name off the list of things CI can differ on.
    git(["symbolic-ref", "HEAD", "refs/heads/main"], chdir: work)
    git(["add", "-A"], chdir: work)
    git(["commit", "-q", "-m", "fixture marketplace"], chdir: work)
    git(["clone", "-q", "--bare", work, bare])

    Repo.new(work, bare)
  end

  # A second commit, pushed to the bare repo — what `marketplace update` has to
  # notice.
  def self.advance(repo : Repo, message : String = "another commit") : String
    File.write(File.join(repo.work, "CHANGES.md"), "#{message}\n")
    git(["add", "-A"], chdir: repo.work)
    git(["commit", "-q", "-m", message], chdir: repo.work)
    git(["push", "-q", repo.bare, "main:main"], chdir: repo.work)
    git(["rev-parse", "HEAD"], chdir: repo.work).strip
  end

  def self.head(dir : String) : String
    git(["rev-parse", "HEAD"], chdir: dir).strip
  end

  MANIFEST = <<-JSON
    {
      "name": "fixture",
      "owner": {"name": "Smith Fixture"},
      "description": "A marketplace built for smith's own tests",
      "metadata": {"pluginRoot": "./plugins"},
      "plugins": [
        {"name": "skills-demo", "source": "./plugins/skills-demo", "description": "Two skills in a skills/ directory"},
        {"name": "root-skill", "source": "./plugins/root-skill", "description": "One skill at the plugin root"},
        {"name": "agents-demo", "source": "agents-demo", "description": "One agent definition", "version": "2.0.0"},
        {"name": "hooky", "source": "./plugins/hooky", "description": "Carries components smith does not load"},
        {"name": "npm-demo", "source": {"source": "npm", "package": "@acme/plugin"}, "description": "Refused on purpose"},
        {"name": "subdir-demo", "source": {"source": "git-subdir", "url": "https://example.invalid/repo.git", "path": "sub"}, "description": "Phase 2"},
        {"name": "escape-demo", "source": "../../../etc", "description": "Path traversal, refused"}
      ]
    }
    JSON

  def self.write_tree(work : String) : Nil
    write(work, ".claude-plugin/marketplace.json", MANIFEST)

    # A plugin with a skills/ directory. `deploy` exists to collide with a
    # local skill of the same name; `alpha` exists not to.
    write(work, "plugins/skills-demo/.claude-plugin/plugin.json", <<-JSON)
      {"name": "skills-demo", "description": "Two skills", "version": "1.2.0", "author": {"name": "Fixture"}}
      JSON
    write(work, "plugins/skills-demo/skills/alpha/SKILL.md", <<-MD)
      ---
      name: alpha
      description: A skill whose bare name nothing else claims.
      ---
      Run the alpha procedure and report back.
      MD
    write(work, "plugins/skills-demo/skills/deploy/SKILL.md", <<-MD)
      ---
      name: deploy
      description: A skill whose bare name collides with a local one.
      ---
      Deploy the thing, the plugin way.
      MD

    # A plugin that is one skill, at its root.
    write(work, "plugins/root-skill/.claude-plugin/plugin.json", <<-JSON)
      {"name": "root-skill", "description": "One skill at the plugin root", "version": "0.1.0"}
      JSON
    write(work, "plugins/root-skill/SKILL.md", <<-MD)
      ---
      name: summarise
      description: Summarise a file in three bullets.
      ---
      Read the file and summarise it in exactly three bullets.
      MD

    # A plugin of agent definitions, carrying frontmatter keys smith has no
    # meaning for.
    write(work, "plugins/agents-demo/agents/auditor.md", <<-MD)
      ---
      name: auditor
      description: Audits a diff for licence headers.
      tools: read_file, grep
      mode: inspect
      maxTurns: 12
      isolation: worktree
      ---
      You check every changed file for a licence header.
      MD

    # A plugin whose interesting parts smith refuses to load.
    write(work, "plugins/hooky/.claude-plugin/plugin.json", <<-JSON)
      {
        "name": "hooky",
        "description": "Carries components smith does not load",
        "version": "3.0.0",
        "hooks": "./hooks/hooks.json",
        "mcpServers": {"demo": {"command": "npx", "args": ["-y", "demo-server"]}},
        "lspServers": {"crystal": {"command": "crystalline"}}
      }
      JSON
    write(work, "plugins/hooky/hooks/hooks.json", <<-JSON)
      {"hooks": {"PreToolUse": [{"matcher": "bash", "hooks": [{"type": "command", "command": "echo blocked"}]}]}}
      JSON
    write(work, "plugins/hooky/.mcp.json", <<-JSON)
      {"mcpServers": {"demo": {"command": "npx", "args": ["-y", "demo-server"]}}}
      JSON
    write(work, "plugins/hooky/skills/gate/SKILL.md", <<-MD)
      ---
      name: gate
      description: The one component of this plugin smith does load.
      ---
      Check the gate.
      MD
  end

  # Public: a spec that changes the fixture mid-flight writes through this too.
  def self.write(root : String, relative : String, content : String) : Nil
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content.ends_with?("\n") ? content : "#{content}\n")
  end
end
