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

    getter name : String
    getter description : String
    getter tools : Array(String)?
    getter model : String?
    getter provider : String?
    getter mode : Subagents::Mode
    getter system_prompt : String
    getter path : String

    def initialize(
      @name : String,
      @description : String,
      @system_prompt : String,
      @path : String,
      @tools : Array(String)? = nil,
      @model : String? = nil,
      @provider : String? = nil,
      @mode : Subagents::Mode = Subagents::Mode::Work,
    )
    end

    def tool_names : Array(String)
      @tools || (mode.inspect? ? INSPECT_TOOLS : WORK_TOOLS)
    end
  end

  class Catalog
    DIRECTORY_NAME = "agents"

    # A definition that did not read the way its author meant it to. Held
    # rather than announced on the spot, because whether the file is the one in
    # effect is only known once every source has been read — and a warning
    # about a file that lost a name clash reads as "the agent you are using is
    # broken".
    private record Problem, name : String, path : String, reason : String

    getter agents = Hash(String, Definition).new

    # Per agent name, the paths that lost the clash. Which source won was
    # otherwise nowhere visible, and the warnings may name the files that lost.
    getter shadowed = Hash(String, Array(String)).new

    @problems = Array(Problem).new

    # Global first, then project, so a project definition overwrites a global
    # one of the same name — the rule skills and config already follow.
    def self.discover(workspace_dir : String = Dir.current, warn_io : IO = STDERR) : Catalog
      catalog = Catalog.new

      catalog.load_dir(File.join(Smith.home_dir, DIRECTORY_NAME))
      catalog.load_dir(File.join(workspace_dir, ".smith", DIRECTORY_NAME))
      catalog.report(warn_io)

      catalog
    end

    def load_dir(dir : String) : Nil
      return unless directory?(dir)

      Dir.children(dir).sort.each do |child|
        next unless child.ends_with?(".md")

        path = File.join(dir, child)
        next unless regular_file?(File.basename(child, ".md"), path)

        definition = parse(path, File.basename(child, ".md"))
        next if definition.nil?

        if previous = @agents[definition.name]?
          (@shadowed[definition.name] ||= Array(String).new) << previous.path
        end

        @agents[definition.name] = definition
      end
    end

    # Everything worth saying about the files just read, on the channel agent
    # warnings have always used. Called once, after the last source, so a line
    # can name the file that won whenever the file it warns about lost.
    def report(warn_io : IO = STDERR) : Nil
      @problems.each do |problem|
        line = "⚠️  Agent '#{problem.name}' (#{problem.path}): #{problem.reason}"
        winner = @agents[problem.name]?
        line += " The '#{problem.name}' in this catalog comes from #{winner.path} instead." if winner && winner.path != problem.path

        warn_io.puts line
      end

      @problems.clear
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

    # Only a regular file can be read. `File.file?` answers that, but it raises
    # on a symlink loop — which is a file smith cannot read like any other, and
    # belongs in a warning rather than in a stack trace. A FIFO would block
    # `File.read` until something wrote to it, so it never gets that far.
    private def regular_file?(name : String, path : String) : Bool
      info = File.info?(path)
      return false if info.nil?
      return true if info.file?

      @problems << Problem.new(name, path, "not a regular file (#{info.type.to_s.downcase}); it was skipped.")
      false
    rescue ex : File::Error
      @problems << Problem.new(name, path, "could not be read (#{ex.os_error.try(&.message) || ex.message}); it was skipped.")
      false
    end

    def [](name : String) : Definition?
      @agents[name]?
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

    private def parse(path : String, filename : String) : Definition?
      content = read_definition(path)
      return nil if content.nil?

      document = Frontmatter.parse(content)
      name = document["name"] || filename

      description = document["description"]
      # Loaded anyway — a usable agent with a poor listing beats a missing one —
      # but a header that did not read costs the agent its name and its
      # description, and puts the raw `---` lines in the system prompt.
      if document.malformed?
        @problems << Problem.new(name, path, "the frontmatter could not be read as 'key: value' lines; what it declared was ignored.")
      elsif description.nil?
        @problems << Problem.new(name, path, "no description in the frontmatter; the model will not know when to use it.")
      end

      Definition.new(
        name: name,
        description: description || "No description provided.",
        system_prompt: document.body.strip,
        path: path,
        tools: document.list("tools"),
        model: document["model"],
        provider: document["provider"],
        mode: Subagents::Mode.from_string(document["mode"] || "work")
      )
    end

    # One unreadable file must not take every smith command with it: the catalog
    # is built in the CLI's constructor, before it knows what was asked for.
    private def read_definition(path : String) : String?
      content = File.read(path)
      # PCRE refuses to match against bytes that are not UTF-8, so a file saved
      # as Latin-1 raises out of the parser rather than parsing badly.
      return content if content.valid_encoding?

      @problems << Problem.new(File.basename(path, ".md"), path, "the file is not valid UTF-8; it was skipped.")
      nil
    rescue ex : IO::Error
      @problems << Problem.new(File.basename(path, ".md"), path, "the file could not be read (#{ex.os_error.try(&.message) || ex.message}); it was skipped.")
      nil
    end
  end
end
