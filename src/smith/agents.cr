require "file_utils"
require "./paths"
require "./frontmatter"
require "./subagents"

module Smith::Agents
  # A specialised subagent, defined in a markdown file rather than compiled in.
  #
  # Flat files rather than the directory-per-item layout skills use: an agent
  # is one definition, not a bundle of a file plus its trimmings.
  struct Definition
    # The read-only set is what Mode::Inspect has always meant; the work set
    # adds the mutating tools. A definition's own `tools:` overrides both.
    INSPECT_TOOLS = %w[read_file grep glob]
    WORK_TOOLS    = INSPECT_TOOLS + %w[bash write_file edit_file]

    # The `agent_type` value that always works. For a plugin agent this is the
    # namespaced `<plugin>:<agent>` form.
    getter name : String
    getter description : String
    getter tools : Array(String)?
    getter model : String?
    getter provider : String?
    getter mode : Subagents::Mode
    getter system_prompt : String
    getter path : String
    # Set only for a definition that came from an installed plugin.
    getter plugin : String?
    getter marketplace : String?
    # The name the file itself carries, without the `<plugin>:` prefix.
    getter bare_name : String

    def initialize(
      @name : String,
      @description : String,
      @system_prompt : String,
      @path : String,
      @tools : Array(String)? = nil,
      @model : String? = nil,
      @provider : String? = nil,
      @mode : Subagents::Mode = Subagents::Mode::Work,
      @plugin : String? = nil,
      @marketplace : String? = nil,
      bare_name : String? = nil,
    )
      @bare_name = bare_name || @name
    end

    def plugin? : Bool
      !@plugin.nil?
    end

    def tool_names : Array(String)
      @tools || (mode.inspect? ? INSPECT_TOOLS : WORK_TOOLS)
    end
  end

  class Catalog
    DIRECTORY_NAME = "agents"

    # Stands in for a plugin name where the failure is above any single plugin
    # — the plugin tree itself. Never rendered; only ever tested for nil-ness,
    # which is what routes a plugin-tree problem away from the startup channel.
    PLUGIN_TREE = "plugins"

    # A definition that did not read the way its author meant it to. Held
    # rather than announced on the spot, because whether the file is the one in
    # effect is only known once every source has been read — and a warning
    # about a file that lost a name clash reads as "the agent you are using is
    # broken".
    # `plugin` is set when the file came from an installed plugin, and that is
    # the whole of the difference in where it is reported: see #report.
    # `directory` marks a failure to *list* a directory rather than to read a
    # definition — it has no name and is not an agent, so it renders as itself.
    private record Problem,
      name : String,
      path : String,
      reason : String,
      plugin : String? = nil,
      directory : Bool = false

    getter agents = Hash(String, Definition).new

    # Per agent name, the paths that lost the clash. Which source won was
    # otherwise nowhere visible, and the warnings may name the files that lost.
    getter shadowed = Hash(String, Array(String)).new

    @problems = Array(Problem).new

    # Bare name → the namespaced key it stands for, and the bare names that
    # could not get one. Derived from every source at once, so computed after
    # the last one and dropped whenever another is added.
    @aliases : Hash(String, String)? = nil
    @collisions : Array(String)? = nil
    # Whether `report` has already said its piece. A flag rather than consuming
    # `@problems`, so `warnings` stays the complete view every other reader
    # depends on.
    @reported = false

    # Global first, then plugins, then project, so a project definition
    # overwrites a global one of the same name — the rule skills and config
    # already follow. Plugin definitions are namespaced and so overwrite
    # nothing.
    def self.discover(workspace_dir : String = Dir.current, warn_io : IO = STDERR) : Catalog
      catalog = Catalog.new

      catalog.load_dir(File.join(Smith.home_dir, DIRECTORY_NAME))
      catalog.load_plugins_dir
      catalog.load_dir(File.join(workspace_dir, ".smith", DIRECTORY_NAME))
      catalog.report(warn_io)

      catalog
    end

    def load_dir(dir : String) : Nil
      invalidate
      return unless directory?(dir)

      children(dir, dir).each do |child|
        next unless child.ends_with?(".md")

        path = File.join(dir, child)
        next unless regular_file?(File.basename(child, ".md"), path)

        register(parse(path, File.basename(child, ".md")))
      end
    end

    # Agent definitions from every installed plugin,
    # `installed/<marketplace>/<plugin>/agents/*.md`.
    #
    # A two-level walk of a directory that is usually absent: this is on the
    # startup path of every smith command and stays a directory read.
    def load_plugins_dir(base : String = Smith.installed_plugins_dir) : Nil
      return unless directory?(base)

      children(base, base, PLUGIN_TREE).each do |marketplace|
        # An install stages its copy under a dot-prefixed name and renames it
        # into place, so a dot-prefixed entry is a half-written plugin.
        next if marketplace.starts_with?('.')

        marketplace_dir = File.join(base, marketplace)
        next unless directory?(marketplace_dir)

        children(marketplace, marketplace_dir, marketplace).each do |plugin|
          next if plugin.starts_with?('.')

          plugin_dir = File.join(marketplace_dir, plugin)
          next unless directory?(plugin_dir)

          load_plugin_dir(marketplace, plugin, plugin_dir)
        end
      end
    end

    def load_plugin_dir(marketplace : String, plugin : String, plugin_dir : String) : Nil
      invalidate

      dir = File.join(plugin_dir, DIRECTORY_NAME)
      return unless directory?(dir)

      children(plugin, dir, plugin).each do |child|
        next unless child.ends_with?(".md")

        path = File.join(dir, child)
        next unless regular_file?(File.basename(child, ".md"), path, plugin)

        register(parse(path, File.basename(child, ".md"), marketplace, plugin))
      end
    end

    private def register(definition : Definition?) : Nil
      return if definition.nil?

      if previous = @agents[definition.name]?
        (@shadowed[definition.name] ||= Array(String).new) << previous.path
      end

      @agents[definition.name] = definition
    end

    # Everything worth saying about the files just read. Built once the last
    # source has been read, so a line can name the file that won whenever the
    # file it warns about lost.
    #
    # Kept rather than consumed by `report`, so a later reader — `smith doctor`
    # gathers these into its Environment block, `smith agents list` prints it
    # below the listing — does not have to discover the whole catalog a second
    # time to see them. Complete on purpose: it is the only view that is.
    def warnings : Array(String)
      @problems.map { |problem| render(problem) } + collisions
    end

    # What the reader wrote themselves, plus every name clash, on the channel
    # agent warnings have always used.
    #
    # Definitions from an installed plugin are deliberately **not** on this
    # channel. This runs in the CLI's constructor, so every line here lands in
    # front of every command — `smith -v` included — forever. That is the right
    # trade for a file the reader owns and can fix in a second. It is the wrong
    # one for a plugin: those arrive by the dozen, are written for another
    # harness (so unread fields are the normal case, not the exception), and
    # belong to somebody else. They wait for `warnings`, which
    # `smith agents list` and `smith doctor` print, and `smith plugin install`
    # says them once for the plugin being installed.
    #
    # A name clash is the exception among exceptions, and it is an exception
    # about kind rather than source: it changes what a bare name *does*, right
    # now, for someone who never typed the plugin's name.
    #
    # Said once per catalog rather than once per call, and without consuming
    # anything — `warnings` has to stay complete for the readers above.
    def report(warn_io : IO = STDERR) : Nil
      return if @reported

      @problems.each do |problem|
        warn_io.puts render(problem) if problem.plugin.nil?
      end
      collisions.each { |line| warn_io.puts line }

      @reported = true
    end

    private def render(problem : Problem) : String
      # A directory smith could not read is not an agent, and calling it one
      # made the line read as though a definition were broken.
      return "⚠️  #{problem.path}: #{problem.reason}" if problem.directory

      line = "⚠️  Agent '#{problem.name}' (#{problem.path}): #{problem.reason}"
      winner = @agents[problem.name]?
      return line if winner.nil? || winner.path == problem.path

      "#{line} The '#{problem.name}' in this catalog comes from #{winner.path} instead."
    end

    # The `agent_type` values that work: every key, plus every bare name
    # unambiguous enough to stand for one.
    def invocation_names : Array(String)
      @agents.keys + bare_aliases.keys
    end

    # A plugin agent's namespaced `<plugin>:<name>` is its guaranteed address;
    # the bare name works too, but only where nothing else claims it.
    def bare_aliases : Hash(String, String)
      build_aliases if @aliases.nil?
      @aliases.not_nil!
    end

    def collisions : Array(String)
      build_aliases if @collisions.nil?
      @collisions.not_nil!
    end

    private def invalidate : Nil
      @aliases = nil
      @collisions = nil
      # A source added after a report can bring a clash the last report could
      # not have known about, so "said it once" is only good for the catalog as
      # it stood.
      @reported = false
    end

    private def build_aliases : Nil
      aliases = Hash(String, String).new
      collisions = Array(String).new

      by_bare = Hash(String, Array(String)).new
      @agents.each do |key, definition|
        next unless definition.plugin?
        (by_bare[definition.bare_name] ||= Array(String).new) << key
      end

      by_bare.each do |bare, keys|
        local = @agents[bare]?
        if local && !local.plugin?
          collisions << "⚠️  Agent '#{bare}' is defined outside any plugin (#{local.path}) and by #{keys.join(", ")}; the bare name stays the one at #{local.path}, and the plugin agent answers only to its full name."
          next
        end

        if keys.size > 1
          collisions << "⚠️  Agent name '#{bare}' is claimed by #{keys.join(" and ")}; the bare name resolves to neither, so use the full name."
          next
        end

        aliases[bare] = keys.first
      end

      @aliases = aliases
      @collisions = collisions
    end

    # A source directory that is absent is the ordinary case, and one that
    # cannot be stat'ed at all — a symlink loop where `.smith/agents` should be
    # — is a broken workspace rather than a broken definition. Neither is worth
    # a line; neither may raise either, since this runs before smith knows what
    # was asked for.
    private def directory?(path : String) : Bool
      File.info?(path).try(&.directory?) || false
    rescue File::Error
      false
    end

    # `Dir.children` raises where a directory cannot be *read*, which the stat
    # guard above does not cover: `chmod 000` on a directory under
    # `plugins/installed/` is enough, and that is the one tree a third-party
    # install writes into. This runs before smith knows what was asked for, so
    # it may not raise.
    private def children(name : String, path : String, plugin : String? = nil) : Array(String)
      Dir.children(path).sort
    rescue ex : File::Error
      @problems << Problem.new(name, path, "could not be listed (#{ex.os_error.try(&.message) || ex.message}); it was skipped.",
        plugin, directory: true)
      Array(String).new
    end

    # Only a regular file can be read. `File.file?` answers that, but it raises
    # on a symlink loop — which is a file smith cannot read like any other, and
    # belongs in a warning rather than in a stack trace. A FIFO would block
    # `File.read` until something wrote to it, so it never gets that far.
    private def regular_file?(name : String, path : String, plugin : String? = nil) : Bool
      info = File.info?(path)
      return false if info.nil?
      return true if info.file?

      @problems << Problem.new(name, path, "not a regular file (#{info.type.to_s.downcase}); it was skipped.", plugin)
      false
    rescue ex : File::Error
      @problems << Problem.new(name, path, "could not be read (#{ex.os_error.try(&.message) || ex.message}); it was skipped.", plugin)
      false
    end

    # Exact name first, then the bare-name fallback. A colliding bare name
    # resolves to nothing, never to a guess.
    def [](name : String) : Definition?
      if definition = @agents[name]?
        return definition
      end

      key = bare_aliases[name]?
      key ? @agents[key]? : nil
    end

    # Shown to the main model in the agent tool's description, so it can pick
    # the right specialist rather than guessing.
    def summary_prompt : String?
      return nil if @agents.empty?

      String.build do |str|
        str.puts "\n\nAvailable agent_type values:"
        @agents.values.each do |agent|
          str.puts "- #{agent.name}: #{agent.description}"
        end
      end
    end

    # Everything smith acts on. A definition written for Claude Code may carry
    # more — `maxTurns`, `disallowedTools`, `memory`, `isolation` — and those
    # are ignored rather than approximated.
    KNOWN_FIELDS = %w[name description tools model provider mode]

    private def parse(path : String, filename : String, marketplace : String? = nil, plugin : String? = nil) : Definition?
      content = read_definition(path, plugin)
      return nil if content.nil?

      document = Frontmatter.parse(content)
      bare = document["name"] || filename
      # A plugin definition is keyed by its namespaced name, so it neither
      # replaces a local definition nor is replaced by one.
      name = plugin ? "#{plugin}:#{bare}" : bare

      description = document["description"]
      # Loaded anyway — a usable agent with a poor listing beats a missing one —
      # but a header that did not read costs the agent its name and its
      # description, and puts the raw `---` lines in the system prompt.
      if document.malformed?
        @problems << Problem.new(name, path, "the frontmatter could not be read as 'key: value' lines; what it declared was ignored.", plugin)
      elsif description.nil?
        @problems << Problem.new(name, path, "no description in the frontmatter; the model will not know when to use it.", plugin)
      end

      # Only for plugin definitions: a local file's extra keys are its author's
      # own business, but a plugin was written against another harness and its
      # unread fields are the difference between what it promises and what it
      # gets. Reported once per file, on the channel agents already warn on.
      if plugin
        ignored = document.fields.keys.reject { |key| KNOWN_FIELDS.includes?(key) }
        unless ignored.empty?
          @problems << Problem.new(name, path, "smith does not act on #{ignored.sort.join(", ")}; #{ignored.size == 1 ? "that field was" : "those fields were"} ignored.", plugin)
        end
      end

      Definition.new(
        name: name,
        description: description || "No description provided.",
        system_prompt: document.body.strip,
        path: path,
        tools: document.list("tools"),
        model: document["model"],
        provider: document["provider"],
        mode: Subagents::Mode.from_string(document["mode"] || "work"),
        plugin: plugin,
        marketplace: marketplace,
        bare_name: bare
      )
    end

    # One unreadable file must not take every smith command with it: the catalog
    # is built in the CLI's constructor, before it knows what was asked for.
    private def read_definition(path : String, plugin : String? = nil) : String?
      content = File.read(path)
      # PCRE refuses to match against bytes that are not UTF-8, so a file saved
      # as Latin-1 raises out of the parser rather than parsing badly.
      return content if content.valid_encoding?

      @problems << Problem.new(File.basename(path, ".md"), path, "the file is not valid UTF-8; it was skipped.", plugin)
      nil
    rescue ex : IO::Error
      @problems << Problem.new(File.basename(path, ".md"), path, "the file could not be read (#{ex.os_error.try(&.message) || ex.message}); it was skipped.", plugin)
      nil
    end
  end
end
