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

    getter agents = Hash(String, Definition).new

    # Global first, then project, so a project definition overwrites a global
    # one of the same name — the rule skills and config already follow.
    def self.discover(workspace_dir : String = Dir.current, warn_io : IO = STDERR) : Catalog
      catalog = Catalog.new

      catalog.load_dir(File.join(Smith.home_dir, DIRECTORY_NAME), warn_io)
      catalog.load_dir(File.join(workspace_dir, ".smith", DIRECTORY_NAME), warn_io)

      catalog
    end

    def load_dir(dir : String, warn_io : IO = STDERR) : Nil
      return unless Dir.exists?(dir)

      Dir.children(dir).sort.each do |child|
        next unless child.ends_with?(".md")

        path = File.join(dir, child)
        next unless File.file?(path)

        definition = parse(path, File.basename(child, ".md"), warn_io)
        @agents[definition.name] = definition if definition
      end
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

    private def parse(path : String, filename : String, warn_io : IO) : Definition?
      content = read_definition(path, warn_io)
      return nil if content.nil?

      document = Frontmatter.parse(content)
      name = document["name"] || filename

      description = document["description"]
      # Loaded anyway — a usable agent with a poor listing beats a missing one —
      # but a header that did not read costs the agent its name and its
      # description, and puts the raw `---` lines in the system prompt.
      if document.malformed?
        warn_io.puts "⚠️  Agent '#{name}' (#{path}): the frontmatter could not be read as 'key: value' lines; what it declared was ignored."
      elsif description.nil?
        warn_io.puts "⚠️  Agent '#{name}' (#{path}) has no description; the model will not know when to use it."
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
    private def read_definition(path : String, warn_io : IO) : String?
      content = File.read(path)
      # PCRE refuses to match against bytes that are not UTF-8, so a file saved
      # as Latin-1 raises out of the parser rather than parsing badly.
      return content if content.valid_encoding?

      warn_io.puts "⚠️  Agent definition #{path} is not valid UTF-8; it was skipped."
      nil
    rescue ex : IO::Error
      warn_io.puts "⚠️  Agent definition #{path} could not be read (#{ex.os_error.try(&.message) || ex.message}); it was skipped."
      nil
    end
  end
end
