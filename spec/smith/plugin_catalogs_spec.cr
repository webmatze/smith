require "../spec_helper"
require "../../src/smith/skills"
require "../../src/smith/agents"

# The namespace rule, from both catalogs' side.
#
# A plugin skill is `<plugin>:<name>`, always. It answers to its bare name as
# well, but only where nothing else claims that name — installing a plugin must
# never quietly change what an existing `/deploy` means.
#
# Every spec writes into a throwaway SMITH_HOME: installed plugins live under
# it, and the developer's real ~/.smith may never be read or written.
private def with_plugins(
  plugins : Hash(String, Hash(String, String)) = {} of String => Hash(String, String),
  project : Hash(String, String) = {} of String => String,
  global : Hash(String, String) = {} of String => String,
  &
)
  temp_dir = File.join(Dir.tempdir, "smith_plugin_cat_#{Random::Secure.hex(6)}")
  home = File.join(temp_dir, "smith-home")
  FileUtils.mkdir_p(home)

  # "marketplace/plugin" => {"relative/path" => content}
  plugins.each do |reference, files|
    marketplace, _, plugin = reference.partition("/")
    base = File.join(home, "plugins", "installed", marketplace, plugin)
    files.each do |relative, content|
      path = File.join(base, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
    FileUtils.mkdir_p(base)
  end

  project.each do |name, content|
    dir = File.join(temp_dir, ".smith", "skills", name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "SKILL.md"), content)
  end

  global.each do |name, content|
    dir = File.join(home, "agents")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{name}.md"), content)
  end

  previous = ENV["SMITH_HOME"]?
  ENV["SMITH_HOME"] = home
  begin
    yield temp_dir
  ensure
    previous ? (ENV["SMITH_HOME"] = previous) : ENV.delete("SMITH_HOME")
    remove_tree(temp_dir)
  end
end

private def skill(name : String, description : String = "Does #{name}.", body : String = "The #{name} body.") : String
  "---\nname: #{name}\ndescription: #{description}\n---\n#{body}"
end

private def agent(name : String, extra : String = "") : String
  "---\nname: #{name}\ndescription: Does #{name}.\n#{extra}---\nThe #{name} prompt."
end

describe "plugin skills" do
  it "loads skills/<name>/SKILL.md under the plugin's namespace" do
    with_plugins({"fixture/skills-demo" => {
      "skills/alpha/SKILL.md" => skill("alpha"),
      "skills/beta/SKILL.md"  => skill("beta"),
    }}) do |dir|
      catalog = Smith::Skills::Catalog.discover(workspace_dir: dir)

      catalog.skills.keys.sort.should eq(["skills-demo:alpha", "skills-demo:beta"])
      entry = catalog.skills["skills-demo:alpha"]
      entry.plugin.should eq("skills-demo")
      entry.marketplace.should eq("fixture")
      entry.bare_name.should eq("alpha")
      entry.plugin?.should be_true
    end
  end

  it "reads a root SKILL.md as the plugin's single skill" do
    with_plugins({"fixture/root-skill" => {"SKILL.md" => skill("summarise")}}) do |dir|
      catalog = Smith::Skills::Catalog.discover(workspace_dir: dir)

      catalog.skills.keys.should eq(["root-skill:summarise"])
    end
  end

  it "ignores a root SKILL.md when the plugin has a skills/ directory" do
    with_plugins({"fixture/both" => {
      "SKILL.md"             => skill("ignored"),
      "skills/kept/SKILL.md" => skill("kept"),
    }}) do |dir|
      catalog = Smith::Skills::Catalog.discover(workspace_dir: dir)

      catalog.skills.keys.should eq(["both:kept"])
    end
  end

  it "falls back to the directory name when the frontmatter names none" do
    with_plugins({"fixture/p" => {"skills/from-dir/SKILL.md" => "no frontmatter here"}}) do |dir|
      catalog = Smith::Skills::Catalog.discover(workspace_dir: dir)

      catalog.skills.keys.should eq(["p:from-dir"])
      catalog.skills["p:from-dir"].bare_name.should eq("from-dir")
    end
  end

  it "expands the namespaced form as /plugin:skill and $plugin:skill" do
    with_plugins({"fixture/skills-demo" => {"skills/alpha/SKILL.md" => skill("alpha")}}) do |dir|
      catalog = Smith::Skills::Catalog.discover(workspace_dir: dir)

      slash = catalog.expand_prompt("/skills-demo:alpha src/main.cr")
      slash.should contain("Execute skill 'skills-demo:alpha'")
      slash.should contain("Arguments: src/main.cr")
      slash.should contain("The alpha body.")

      dollar = catalog.expand_prompt("Please apply $skills-demo:alpha now")
      dollar.should contain("Skill Context: skills-demo:alpha")
      dollar.should contain("The alpha body.")
    end
  end

  it "also answers to a bare name nothing else claims" do
    with_plugins({"fixture/skills-demo" => {"skills/alpha/SKILL.md" => skill("alpha")}}) do |dir|
      catalog = Smith::Skills::Catalog.discover(workspace_dir: dir)

      catalog.bare_aliases.should eq({"alpha" => "skills-demo:alpha"})
      catalog.resolve("alpha").not_nil!.name.should eq("skills-demo:alpha")
      catalog.invocation_names.sort.should eq(["alpha", "skills-demo:alpha"])

      catalog.expand_prompt("/alpha").should contain("Execute skill 'skills-demo:alpha'")
      catalog.expand_prompt("do $alpha please").should contain("The alpha body.")
      catalog.collisions.should be_empty
    end
  end

  it "refuses the bare name when a local skill already has it, and says so once" do
    with_plugins(
      plugins: {"fixture/skills-demo" => {"skills/deploy/SKILL.md" => skill("deploy", body: "The plugin deploy.")}},
      project: {"deploy" => skill("deploy", body: "The local deploy.")}
    ) do |dir|
      catalog = Smith::Skills::Catalog.discover(workspace_dir: dir, warn_io: IO::Memory.new)

      catalog.skills.keys.sort.should eq(["deploy", "skills-demo:deploy"])
      catalog.bare_aliases.should be_empty

      # The bare name keeps meaning what it meant before the plugin arrived.
      catalog.resolve("deploy").not_nil!.body.should eq("The local deploy.")
      catalog.expand_prompt("/deploy").should contain("The local deploy.")
      catalog.expand_prompt("/deploy").should_not contain("The plugin deploy.")

      # …and the namespaced form still reaches the plugin's.
      catalog.expand_prompt("/skills-demo:deploy").should contain("The plugin deploy.")

      catalog.collisions.size.should eq(1)
      catalog.collisions.first.should contain("'deploy'")
      catalog.collisions.first.should contain("skills-demo:deploy")
      catalog.warnings.count { |line| line.includes?("'deploy'") }.should eq(1)
    end
  end

  it "refuses the bare name when two plugins claim it" do
    with_plugins({
      "fixture/one" => {"skills/shared/SKILL.md" => skill("shared", body: "From one.")},
      "fixture/two" => {"skills/shared/SKILL.md" => skill("shared", body: "From two.")},
    }) do |dir|
      catalog = Smith::Skills::Catalog.discover(workspace_dir: dir, warn_io: IO::Memory.new)

      catalog.bare_aliases.should be_empty
      catalog.resolve("shared").should be_nil
      catalog.expand_prompt("/shared").should eq("/shared")

      catalog.collisions.size.should eq(1)
      catalog.collisions.first.should contain("one:shared")
      catalog.collisions.first.should contain("two:shared")

      catalog.resolve("one:shared").not_nil!.body.should eq("From one.")
      catalog.resolve("two:shared").not_nil!.body.should eq("From two.")
    end
  end

  it "does not let a bare alias steal the plugin half of a namespaced reference" do
    with_plugins({
      # `$demo:alpha` contains `$demo`, and `demo` is a bare alias here.
      "fixture/other" => {"skills/demo/SKILL.md" => skill("demo", body: "The demo body.")},
      "fixture/demo"  => {"skills/alpha/SKILL.md" => skill("alpha", body: "The alpha body.")},
    }) do |dir|
      catalog = Smith::Skills::Catalog.discover(workspace_dir: dir, warn_io: IO::Memory.new)

      expanded = catalog.expand_prompt("run $demo:alpha")
      expanded.should contain("The alpha body.")
      expanded.should_not contain("The demo body.")
    end
  end

  # The same trap one level down: `demo` here is a real catalog key, not an
  # alias, and a guard applied only to the alias path let `$demo:alpha` inject
  # the local skill's body alongside the one that was actually asked for.
  it "does not let a real key steal the plugin half of a namespaced reference" do
    with_plugins(
      plugins: {"fixture/demo" => {"skills/alpha/SKILL.md" => skill("alpha", body: "The alpha body.")}},
      project: {"demo" => skill("demo", body: "The local demo body.")}
    ) do |dir|
      catalog = Smith::Skills::Catalog.discover(workspace_dir: dir, warn_io: IO::Memory.new)
      catalog.skills.keys.sort.should eq(["demo", "demo:alpha"])

      expanded = catalog.expand_prompt("run $demo:alpha")
      expanded.should contain("The alpha body.")
      expanded.should_not contain("The local demo body.")

      # …while a plain reference to the local skill still works, and so does one
      # whose colon is only punctuation.
      catalog.expand_prompt("run $demo now").should contain("The local demo body.")
      catalog.expand_prompt("about $demo: it is local").should contain("The local demo body.")
    end
  end

  it "keeps working when a plugin's SKILL.md cannot be read" do
    with_plugins({"fixture/broken" => {"skills/ok/SKILL.md" => skill("ok")}}) do |dir|
      loop_dir = File.join(Smith.installed_plugins_dir, "fixture", "broken", "skills", "looping")
      File.symlink("looping", loop_dir)

      catalog = Smith::Skills::Catalog.discover(workspace_dir: dir)

      catalog.skills.keys.should eq(["broken:ok"])
      catalog.warnings.size.should eq(1)
      catalog.warnings.first.should contain("could not be read")
    end
  end

  it "costs nothing when no plugin is installed" do
    with_plugins do |dir|
      catalog = Smith::Skills::Catalog.discover(workspace_dir: dir)

      catalog.skills.should be_empty
      catalog.warnings.should be_empty
      catalog.bare_aliases.should be_empty
    end
  end
end

describe "plugin agents" do
  it "loads agents/*.md under the plugin's namespace and resolves both names" do
    with_plugins({"fixture/agents-demo" => {"agents/auditor.md" => agent("auditor")}}) do |dir|
      warnings = IO::Memory.new
      catalog = Smith::Agents::Catalog.discover(workspace_dir: dir, warn_io: warnings)

      catalog.agents.keys.should eq(["agents-demo:auditor"])
      definition = catalog.agents["agents-demo:auditor"]
      definition.plugin.should eq("agents-demo")
      definition.marketplace.should eq("fixture")
      definition.bare_name.should eq("auditor")

      # The `agent` tool's agent_type enum is built from this.
      catalog.invocation_names.sort.should eq(["agents-demo:auditor", "auditor"])
      catalog["auditor"].not_nil!.name.should eq("agents-demo:auditor")
      catalog["agents-demo:auditor"].should_not be_nil
    end
  end

  it "refuses the bare agent name when a global definition already has it" do
    with_plugins(
      plugins: {"fixture/agents-demo" => {"agents/reviewer.md" => agent("reviewer")}},
      global: {"reviewer" => agent("reviewer")}
    ) do |dir|
      warnings = IO::Memory.new
      catalog = Smith::Agents::Catalog.discover(workspace_dir: dir, warn_io: warnings)

      catalog["reviewer"].not_nil!.plugin.should be_nil
      catalog["agents-demo:reviewer"].not_nil!.plugin.should eq("agents-demo")
      catalog.bare_aliases.should be_empty
      catalog.invocation_names.sort.should eq(["agents-demo:reviewer", "reviewer"])

      # A clash is the one thing that does not wait to be asked for: it changes
      # what the bare name does for someone who never typed the plugin's.
      warnings.to_s.should contain("Agent 'reviewer' is defined outside any plugin")
      catalog.warnings.join("\n").should contain("Agent 'reviewer' is defined outside any plugin")
    end
  end

  it "reports a name two plugins claim, once" do
    with_plugins({
      "fixture/one" => {"agents/shared.md" => agent("shared")},
      "fixture/two" => {"agents/shared.md" => agent("shared")},
    }) do |dir|
      warnings = IO::Memory.new
      catalog = Smith::Agents::Catalog.discover(workspace_dir: dir, warn_io: warnings)

      catalog["shared"].should be_nil
      warnings.to_s.lines.count { |line| line.includes?("'shared'") }.should eq(1)
      catalog.warnings.count { |line| line.includes?("'shared'") }.should eq(1)

      # Said once, not once per report.
      again = IO::Memory.new
      catalog.report(again)
      again.to_s.should be_empty
    end
  end

  it "names the frontmatter fields it does not act on, for plugin definitions only" do
    with_plugins(
      plugins: {"fixture/agents-demo" => {"agents/auditor.md" => agent("auditor", "maxTurns: 12\nisolation: worktree\n")}},
      global: {"local" => agent("local", "maxTurns: 12\n")}
    ) do |dir|
      warnings = IO::Memory.new
      catalog = Smith::Agents::Catalog.discover(workspace_dir: dir, warn_io: warnings)

      text = catalog.warnings.join("\n")
      text.should contain("smith does not act on isolation, maxTurns")
      text.should contain("agents-demo:auditor")
      # A local definition's extra keys are its author's own business.
      text.should_not contain("Agent 'local'")
      warnings.to_s.should_not contain("Agent 'local'")
    end
  end

  # A mode smith cannot read is on the plugin channel like every other problem
  # here, and it is safe to be: after the fallback it is a loss of capability,
  # not a grant of one. The listing carries it, and the listing's own `mode:`
  # line marks the fallback whatever the definition's origin.
  it "keeps a plugin's unreadable mode out of startup, and still falls back to inspect" do
    with_plugins(
      plugins: {"fixture/agents-demo" => {"agents/auditor.md" => agent("auditor", "mode: readonly\n")}},
      global: {"local" => agent("local", "mode: inspekt\n")}
    ) do |dir|
      startup = IO::Memory.new
      catalog = Smith::Agents::Catalog.discover(workspace_dir: dir, warn_io: startup)

      catalog.agents["agents-demo:auditor"].mode.should eq(Smith::Subagents::Mode::Inspect)
      catalog.agents["agents-demo:auditor"].mode_label.should contain("readonly")

      text = catalog.warnings.join("\n")
      text.should contain("'readonly' is not a mode")
      # A definition the reader wrote themselves still says so at startup.
      startup.to_s.should contain("'inspekt' is not a mode")
      startup.to_s.should_not contain("readonly")
    end
  end
end

# The reason the two channels are separate at all. A marketplace ships agent
# definitions by the dozen, written for another harness, so unread fields are
# the normal case rather than the exception — and `report` runs in the CLI's
# constructor, in front of *every* command. A plugin the reader installed must
# not be able to make `smith -v` noisy; a file the reader wrote must stay as
# loud as it has always been.
describe "where a plugin's problems are said" do
  it "says nothing at startup for a plugin whose definitions smith cannot fully read" do
    noisy = {} of String => String
    %w[planner writer reviewer estimator groomer].each do |name|
      noisy["agents/#{name}.md"] = agent(name, "memory: project\nmaxTurns: 20\n")
    end
    # A header that never closes: the other half of what a marketplace ships.
    noisy["agents/broken.md"] = "---\nname: broken\ndescription: Never closed\n\nThe broken prompt."

    with_plugins({"big/pm-like" => noisy}) do |dir|
      startup = IO::Memory.new
      catalog = Smith::Agents::Catalog.discover(workspace_dir: dir, warn_io: startup)

      catalog.agents.size.should eq(6)
      startup.to_s.should be_empty

      # Not dropped — reachable, in the command that exists to show it.
      listed = catalog.warnings
      listed.size.should eq(6)
      listed.join("\n").should contain("smith does not act on maxTurns, memory")
      listed.join("\n").should contain("pm-like:broken")
    end
  end

  it "keeps a definition the reader wrote themselves on the startup channel" do
    with_plugins(
      plugins: {"big/pm-like" => {"agents/plugin-one.md" => agent("plugin-one", "maxTurns: 20\n")}},
      global: {"mine" => "---\nname: mine\n---\nNo description here."}
    ) do |dir|
      startup = IO::Memory.new
      catalog = Smith::Agents::Catalog.discover(workspace_dir: dir, warn_io: startup)

      startup.to_s.should contain("Agent 'mine'")
      startup.to_s.should contain("no description")
      startup.to_s.should_not contain("pm-like")

      # And the plugin's is still on the other channel, not lost between them.
      catalog.warnings.join("\n").should contain("pm-like:plugin-one")
      # A second report does not repeat what has already been said.
      again = IO::Memory.new
      catalog.report(again)
      again.to_s.should be_empty
    end
  end

  # The one exception, and the reason the split is by *kind* rather than by
  # source. An unread frontmatter field is informational and can wait to be
  # asked for. A name clash changes what a bare `/name` does, right now, for
  # someone who never typed the plugin's name — so it is said without asking,
  # in both catalogs, once.
  it "still says a name clash at startup, in both catalogs" do
    with_plugins(
      plugins: {"mkt/p" => {
        "skills/demo/SKILL.md" => skill("demo", body: "plugin"),
        "agents/clash.md"      => agent("clash"),
      }},
      project: {"demo" => skill("demo", body: "local")},
      global: {"clash" => agent("clash")}
    ) do |dir|
      skill_io = IO::Memory.new
      Smith::Skills::Catalog.discover(workspace_dir: dir, warn_io: skill_io)
      skill_io.to_s.should contain("Skill 'demo' is defined outside any plugin")

      agent_io = IO::Memory.new
      catalog = Smith::Agents::Catalog.discover(workspace_dir: dir, warn_io: agent_io)
      agent_io.to_s.should contain("Agent 'clash' is defined outside any plugin")

      # Once, not once per report.
      again = IO::Memory.new
      catalog.report(again)
      again.to_s.should be_empty
    end
  end

  it "stays quiet at startup when no name clashes" do
    with_plugins({"mkt/p" => {"skills/alpha/SKILL.md" => skill("alpha"), "agents/auditor.md" => agent("auditor")}}) do |dir|
      skill_io = IO::Memory.new
      Smith::Skills::Catalog.discover(workspace_dir: dir, warn_io: skill_io)
      skill_io.to_s.should be_empty
    end
  end

  # The plugin *tree* is still the plugin tree. A listing failure above any
  # single plugin used to arrive on the startup channel labelled as an "Agent",
  # named by its own full path — which broke the invariant the rest of this
  # block establishes, and made the two catalogs disagree.
  it "says nothing at startup when the plugin tree itself cannot be listed" do
    with_plugins({"mkt/p" => {"agents/a.md" => agent("a"), "skills/s/SKILL.md" => skill("s")}}) do |dir|
      base = Smith.installed_plugins_dir
      File.chmod(base, 0o000)

      begin
        startup = IO::Memory.new
        agents = Smith::Agents::Catalog.discover(workspace_dir: dir, warn_io: startup)
        startup.to_s.should be_empty

        skills_io = IO::Memory.new
        skills = Smith::Skills::Catalog.discover(workspace_dir: dir, warn_io: skills_io)
        skills_io.to_s.should be_empty

        # Reachable in the listings, and reading as a directory rather than as
        # a broken agent or skill.
        [agents.warnings, skills.warnings].each do |lines|
          lines.size.should eq(1)
          lines.first.should contain("could not be listed")
          lines.first.should contain(base)
          lines.first.should_not contain("Agent '")
          lines.first.should_not contain("Skill '")
        end
      ensure
        File.chmod(base, 0o755)
      end
    end
  end

  it "says nothing at startup for a plugin file it cannot read at all" do
    with_plugins({"big/pm-like" => {"agents/fine.md" => agent("fine")}}) do |dir|
      loop_path = File.join(Smith.installed_plugins_dir, "big", "pm-like", "agents", "looping.md")
      File.symlink("looping.md", loop_path)

      startup = IO::Memory.new
      catalog = Smith::Agents::Catalog.discover(workspace_dir: dir, warn_io: startup)

      catalog.agents.keys.should eq(["pm-like:fine"])
      startup.to_s.should be_empty
      catalog.warnings.join("\n").should contain("could not be read")
    end
  end
end
