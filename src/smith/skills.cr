require "path"
require "file_utils"
require "./paths"
require "./frontmatter"

module Smith::Skills
  struct Skill
    getter name : String
    getter description : String
    getter body : String
    getter path : String

    def initialize(@name : String, @description : String, @body : String, @path : String)
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

    def self.discover(workspace_dir : String = Dir.current) : Catalog
      catalog = Catalog.new

      # 1. Global skills in ~/.smith/skills/
      global_skills_dir = File.join(Smith.home_dir, "skills")
      catalog.load_skills_dir(global_skills_dir)

      # 2. Local workspace skills in .smith/skills/, .gemini/skills/, .claude/skills/
      workspace_skills_dirs = [
        File.join(workspace_dir, ".smith", "skills"),
        File.join(workspace_dir, ".gemini", "skills"),
        File.join(workspace_dir, ".agents", "skills"),
      ]

      workspace_skills_dirs.each do |dir|
        catalog.load_skills_dir(dir)
      end

      catalog
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
      @problems.map do |problem|
        line = "⚠️  Skill '#{problem.name}' (#{problem.path}): #{problem.reason}"
        winner = @skills[problem.name]?
        next line if winner.nil? || winner.path == problem.path

        "#{line} The '#{problem.name}' in this catalog comes from #{winner.path} instead."
      end
    end

    def load_skills_dir(dir : String)
      return unless directory?(dir)

      Dir.children(dir).sort.each do |child|
        skill_dir = File.join(dir, child)
        next unless entry_info(child, skill_dir).try(&.directory?)

        skill_file = File.join(skill_dir, "SKILL.md")
        next unless regular_file?(child, skill_file)

        load_skill_file(child, skill_file)
      end
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

    private def load_skill_file(dir_name : String, file_path : String) : Nil
      content = read_skill_file(dir_name, file_path)
      return if content.nil?

      document = Frontmatter.parse(content)
      name = document["name"] || dir_name
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
        path: file_path
      )
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

      # 1. Match slash invocation: /skill-name or /skill-name args...
      if user_text.starts_with?("/")
        parts = user_text.split(" ", 2)
        slash_cmd = parts[0][1..-1] # remove leading slash
        if skill = @skills[slash_cmd]?
          skills_appended << skill
          arg_suffix = parts[1]? ? "\nArguments: #{parts[1]}" : ""
          expanded = "Execute skill '#{skill.name}'#{arg_suffix}"
        end
      end

      # 2. Match $skill-name references in text
      @skills.each do |name, skill|
        pattern = "$#{name}"
        if user_text.includes?(pattern) && !skills_appended.includes?(skill)
          skills_appended << skill
        end
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
  end
end
