require "path"
require "file_utils"
require "./paths"
require "./frontmatter"

module Smith::Skills
  struct Skill
    # The invocation address. For a plugin skill this is the namespaced
    # `<plugin>:<skill>` form, which is the one that is always valid.
    getter name : String
    getter description : String
    getter body : String
    getter path : String
    # Set only for a skill that came from an installed plugin.
    getter plugin : String?
    getter marketplace : String?
    # The name the file itself carries, without the `<plugin>:` prefix.
    getter bare_name : String

    def initialize(
      @name : String,
      @description : String,
      @body : String,
      @path : String,
      @plugin : String? = nil,
      @marketplace : String? = nil,
      bare_name : String? = nil,
    )
      @bare_name = bare_name || @name
    end

    def plugin? : Bool
      !@plugin.nil?
    end
  end

  class Catalog
    # A file that did not read the way its author meant it to. Held as data
    # rather than as a finished line because whether the file is the one in
    # effect is only known once every source has been read.
    private record Problem, name : String, path : String, reason : String

    getter skills = Hash(String, Skill).new

    # Per skill name, the paths that lost the clash. Sources are read global
    # first, so a project file of the same name replaces a global one — and
    # which file won was, until now, nowhere visible.
    getter shadowed = Hash(String, Array(String)).new

    @problems = Array(Problem).new

    # Bare name → the namespaced key it stands for, and the bare names that
    # could not get one. Both are derived from *every* source at once, so they
    # are computed after the last one has been read and thrown away whenever
    # another is added.
    @aliases : Hash(String, String)? = nil
    @collisions : Array(String)? = nil
    @collisions_reported = false

    # `warn_io` carries exactly one kind of line: a name clash. Everything else
    # this catalog has to say waits for `smith skills list`, because it is built
    # in the CLI's constructor and would otherwise print before every command's
    # own output. A clash is the exception because it changes what a bare
    # `/name` *does* for someone who never typed the plugin's name.
    def self.discover(workspace_dir : String = Dir.current, warn_io : IO = STDERR) : Catalog
      catalog = Catalog.new

      # 1. Global skills in ~/.smith/skills/
      global_skills_dir = File.join(Smith.home_dir, "skills")
      catalog.load_skills_dir(global_skills_dir)

      # 2. Skills from installed plugins. Only the directory tree is read — no
      # git, no network, no JSON — because this runs on every smith invocation.
      catalog.load_plugins_dir

      # 3. Local workspace skills in .smith/skills/, .gemini/skills/, .claude/skills/
      workspace_skills_dirs = [
        File.join(workspace_dir, ".smith", "skills"),
        File.join(workspace_dir, ".gemini", "skills"),
        File.join(workspace_dir, ".agents", "skills"),
      ]

      workspace_skills_dirs.each do |dir|
        catalog.load_skills_dir(dir)
      end

      catalog.report_collisions(warn_io)

      catalog
    end

    # See the note on `discover`. Once per catalog, not once per call.
    def report_collisions(warn_io : IO = STDERR) : Nil
      return if @collisions_reported

      collisions.each { |line| warn_io.puts line }
      @collisions_reported = true
    end

    # Rendered by `smith skills list`. Collected rather than written to a
    # `warn_io` the way agents do it: the CLI builds both catalogs in its
    # constructor, so an IO would print before every command's own output.
    #
    # Built here rather than while parsing, because a warning is only honest
    # once it can say whether the file it names is the one in effect. Warning
    # about a shadowed file without saying so reads as "your working skill is
    # broken".
    def warnings : Array(String)
      lines = @problems.map do |problem|
        line = "⚠️  Skill '#{problem.name}' (#{problem.path}): #{problem.reason}"
        winner = @skills[problem.name]?
        next line if winner.nil? || winner.path == problem.path

        "#{line} The '#{problem.name}' in this catalog comes from #{winner.path} instead."
      end

      lines + collisions
    end

    def load_skills_dir(dir : String)
      invalidate
      return unless directory?(dir)

      children(dir, dir).each do |child|
        skill_dir = File.join(dir, child)
        next unless entry_info(child, skill_dir).try(&.directory?)

        skill_file = File.join(skill_dir, "SKILL.md")
        next unless regular_file?(child, skill_file)

        load_skill_file(child, skill_file)
      end
    end

    # Skills from every installed plugin, `installed/<marketplace>/<plugin>/`.
    #
    # A two-level walk of a directory that is usually absent and never deep:
    # this is on the startup path of every single smith command, so it may not
    # grow a git call, a network call or an unbounded walk.
    def load_plugins_dir(base : String = Smith.installed_plugins_dir) : Nil
      return unless directory?(base)

      children(base, base).each do |marketplace|
        # An install stages its copy under a dot-prefixed name and renames it
        # into place, so a dot-prefixed entry is a half-written plugin, never
        # one to load.
        next if marketplace.starts_with?('.')

        marketplace_dir = File.join(base, marketplace)
        next unless entry_info(marketplace, marketplace_dir).try(&.directory?)

        children(marketplace, marketplace_dir).each do |plugin|
          next if plugin.starts_with?('.')

          plugin_dir = File.join(marketplace_dir, plugin)
          next unless entry_info(plugin, plugin_dir).try(&.directory?)

          load_plugin_dir(marketplace, plugin, plugin_dir)
        end
      end
    end

    # One plugin's skills: `skills/<name>/SKILL.md`, or — only where the plugin
    # has no `skills/` directory at all — a single `SKILL.md` at its root.
    def load_plugin_dir(marketplace : String, plugin : String, plugin_dir : String) : Nil
      invalidate

      skills_dir = File.join(plugin_dir, "skills")
      if directory?(skills_dir)
        children(plugin, skills_dir).each do |child|
          skill_dir = File.join(skills_dir, child)
          next unless entry_info(child, skill_dir).try(&.directory?)

          skill_file = File.join(skill_dir, "SKILL.md")
          next unless regular_file?(child, skill_file)

          load_skill_file(child, skill_file, marketplace, plugin)
        end

        return
      end

      root_skill = File.join(plugin_dir, "SKILL.md")
      return unless regular_file?(plugin, root_skill)

      load_skill_file(plugin, root_skill, marketplace, plugin)
    end

    # A source directory that is absent is the ordinary case, and one that
    # cannot be stat'ed at all — a symlink loop where `.smith/skills` should be
    # — is a broken workspace rather than a broken skill. Neither is worth a
    # line; neither may raise either, since this runs before smith knows what
    # was asked for.
    private def directory?(path : String) : Bool
      File.info?(path).try(&.directory?) || false
    rescue File::Error
      false
    end

    # `Dir.children` raises where a directory cannot be *read*, which the stat
    # guards do not cover: `chmod 000` on a directory under `plugins/installed/`
    # is enough, and that is the one tree a third-party install writes into.
    # This runs before smith knows what was asked for, so it may not raise —
    # `smith plugin uninstall`, the command that would repair it, is among the
    # ones it would otherwise take down.
    private def children(name : String, path : String) : Array(String)
      Dir.children(path).sort
    rescue ex : File::Error
      @problems << Problem.new(name, path, "could not be listed (#{ex.os_error.try(&.message) || ex.message}); it was skipped.")
      Array(String).new
    end

    # What an entry is, without opening it. `File.info?` answers nil for
    # "absent" but raises for a symlink loop, which is a file smith cannot read
    # like any other and belongs in the list rather than in a stack trace.
    private def entry_info(name : String, path : String) : File::Info?
      File.info?(path)
    rescue ex : File::Error
      @problems << Problem.new(name, path, "could not be read (#{ex.os_error.try(&.message) || ex.message}); it was skipped.")
      nil
    end

    # Only a regular file can be read: a directory raises on read, and a FIFO
    # blocks `File.read` until something writes to it — smith hanging with
    # nothing on screen, which is worse than a crash for being unattributable.
    # Absent stays silent; anything present but unusable is named, because
    # putting it there was deliberate.
    private def regular_file?(name : String, path : String) : Bool
      info = entry_info(name, path)
      return false if info.nil?
      return true if info.file?

      @problems << Problem.new(name, path, "not a regular file (#{info.type.to_s.downcase}); it was skipped.")
      false
    end

    private def load_skill_file(dir_name : String, file_path : String, marketplace : String? = nil, plugin : String? = nil) : Nil
      content = read_skill_file(dir_name, file_path)
      return if content.nil?

      document = Frontmatter.parse(content)
      bare = document["name"] || dir_name
      # A plugin skill is keyed by its namespaced name, so it can neither
      # replace a local skill nor be replaced by one — which is what makes the
      # bare-name rule below a decision rather than an accident of load order.
      name = plugin ? "#{plugin}:#{bare}" : bare
      description = document["description"]

      # Loaded either way — a body still expands, which is the point of a skill
      # — but a header nobody read is a header nobody can trust.
      if document.malformed?
        @problems << Problem.new(name, file_path, frontmatter_reason(document))
      elsif description.nil?
        @problems << Problem.new(name, file_path, "no description in the frontmatter; the model will not know when to use it.")
      end

      if previous = @skills[name]?
        (@shadowed[name] ||= Array(String).new) << previous.path
      end

      @skills[name] = Skill.new(
        name: name,
        description: description || "No description provided.",
        body: document.body,
        path: file_path,
        plugin: plugin,
        marketplace: marketplace,
        bare_name: bare
      )
    end

    # The names `/…` and `$…` accept: every key, plus every bare name that is
    # unambiguous enough to stand for one.
    def invocation_names : Array(String)
      @skills.keys + bare_aliases.keys
    end

    # A plugin skill's namespaced `<plugin>:<name>` is its guaranteed address.
    # It answers to its bare name *as well*, but only where nothing else claims
    # that name — otherwise installing a plugin would quietly change what an
    # existing `/deploy` in someone's notes means.
    def bare_aliases : Hash(String, String)
      build_aliases if @aliases.nil?
      @aliases.not_nil!
    end

    # One line per bare name that had to be refused, reported with the rest of
    # the catalog's warnings rather than printed at startup.
    def collisions : Array(String)
      build_aliases if @collisions.nil?
      @collisions.not_nil!
    end

    # Exact name first, then the bare-name fallback. A colliding bare name
    # resolves to nothing at all — never to a guess.
    def resolve(name : String) : Skill?
      if skill = @skills[name]?
        return skill
      end

      key = bare_aliases[name]?
      key ? @skills[key]? : nil
    end

    private def invalidate : Nil
      @aliases = nil
      @collisions = nil
      @collisions_reported = false
    end

    private def build_aliases : Nil
      aliases = Hash(String, String).new
      collisions = Array(String).new

      by_bare = Hash(String, Array(String)).new
      @skills.each do |key, skill|
        next unless skill.plugin?
        (by_bare[skill.bare_name] ||= Array(String).new) << key
      end

      by_bare.each do |bare, keys|
        local = @skills[bare]?
        if local && !local.plugin?
          collisions << "⚠️  Skill '#{bare}' is defined outside any plugin (#{local.path}) and by #{keys.join(", ")}; '/#{bare}' stays the one at #{local.path}, and the plugin skill answers only to its full name."
          next
        end

        if keys.size > 1
          collisions << "⚠️  Skill name '#{bare}' is claimed by #{keys.join(" and ")}; '/#{bare}' resolves to neither, so use the full name."
          next
        end

        aliases[bare] = keys.first
      end

      @aliases = aliases
      @collisions = collisions
    end

    # Two shapes of broken header, and they need different words: one where
    # nothing at all was read, one where a single line was dropped.
    private def frontmatter_reason(document : Frontmatter::Document) : String
      if document.empty?
        "the frontmatter could not be read — a header opens and closes with a plain '---' line and holds 'key: value' lines; name and description were ignored."
      else
        "a line in the frontmatter is not 'key: value' and was dropped — a value written as a YAML list arrives as no value at all."
      end
    end

    # A file that cannot be read must not take the process with it. The catalogs
    # are built before the CLI knows which command is running, so one unreadable
    # SKILL.md under .smith/skills/ would otherwise brick every smith command,
    # `smith -v` included.
    private def read_skill_file(dir_name : String, file_path : String) : String?
      content = File.read(file_path)
      # PCRE refuses to match against bytes that are not UTF-8, so a file saved
      # as Latin-1 raises out of the parser rather than parsing badly.
      return content if content.valid_encoding?

      @problems << Problem.new(dir_name, file_path, "the file is not valid UTF-8; it was skipped.")
      nil
    rescue ex : IO::Error
      @problems << Problem.new(dir_name, file_path, "the file could not be read (#{ex.os_error.try(&.message) || ex.message}); it was skipped.")
      nil
    end

    def summary_prompt : String?
      return nil if @skills.empty?

      String.build do |str|
        str.puts "\n--- Available Project & Global Skills ---"
        str.puts "You can execute/reference these skills when user mentions $skill-name or /skill-name:"
        @skills.values.each do |skill|
          str.puts "- **#{skill.name}**: #{skill.description}"
        end
      end
    end

    # Expands /skill_name or $skill_name in user prompt if present
    def expand_prompt(user_text : String) : String
      return user_text if @skills.empty?

      expanded = user_text
      skills_appended = Array(Skill).new

      # 1. Match slash invocation: /skill-name, /plugin:skill-name, plus args
      if user_text.starts_with?("/")
        parts = user_text.split(" ", 2)
        slash_cmd = parts[0][1..-1] # remove leading slash
        if skill = resolve(slash_cmd)
          skills_appended << skill
          arg_suffix = parts[1]? ? "\nArguments: #{parts[1]}" : ""
          expanded = "Execute skill '#{skill.name}'#{arg_suffix}"
        end
      end

      # 2. Match $skill-name references in text. Namespaced names first: a
      # `$plugin:skill` also contains `$plugin`, and the full name is the one
      # that was meant.
      @skills.each do |name, skill|
        next if skills_appended.includes?(skill)
        skills_appended << skill if mentions?(user_text, name)
      end

      bare_aliases.each do |bare, key|
        skill = @skills[key]?
        next if skill.nil? || skills_appended.includes?(skill)
        skills_appended << skill if mentions?(user_text, bare)
      end

      # If any skills matched, append full bodies to user turn
      if skills_appended.empty?
        expanded
      else
        String.build do |str|
          str.puts expanded
          skills_appended.each do |sk|
            str.puts "\n--- Skill Context: #{sk.name} (#{sk.path}) ---"
            str.puts sk.body
          end
        end
      end
    end

    # `$name`, where a namespaced reference does not already own the text: the
    # substring `$demo` inside `$demo:alpha` is the *plugin half* of that
    # reference, and must not also pull in a skill that happens to be called
    # `demo` — whether that skill is a bare alias or a key of its own.
    #
    # A colon that merely ends a clause — `$demo: it works` — is not a
    # namespaced reference, so only a colon followed by a non-space counts.
    private def mentions?(text : String, name : String) : Bool
      token = "$#{name}"
      offset = 0

      while index = text.index(token, offset)
        after = index + token.size
        namespaced = text[after]? == ':' && (text[after + 1]?.try { |char| !char.whitespace? } || false)
        return true unless namespaced

        offset = after
      end

      false
    end
  end
end
