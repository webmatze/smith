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
      catalog = Smith::Skills::Catalog.discover(workspace_dir: dir)

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
      catalog = Smith::Skills::Catalog.discover(workspace_dir: dir)

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
      catalog = Smith::Skills::Catalog.discover(workspace_dir: dir)

      expanded = catalog.expand_prompt("run $demo:alpha")
      expanded.should contain("The alpha body.")
      expanded.should_not contain("The demo body.")
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
      warnings.to_s.should contain("Agent 'reviewer' is defined outside any plugin")
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

      # A second report must not repeat a clash that has already been said.
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
      Smith::Agents::Catalog.discover(workspace_dir: dir, warn_io: warnings)

      text = warnings.to_s
      text.should contain("smith does not act on isolation, maxTurns")
      text.should contain("agents-demo:auditor")
      # A local definition's extra keys are its author's own business.
      text.should_not contain("Agent 'local'")
    end
  end
end
