require "json"
require "./tool"

module Smith::Tools
  enum Decision
    Allow
    Ask
    Deny
    # No rule had anything to say — fall back to the configured mode.
    Unset
  end

  # One `tool(pattern)` entry. What `pattern` means depends on the tool: for
  # `bash` it matches the command, for the file tools the path.
  struct Rule
    getter tool : String
    getter pattern : String

    # Tools whose `pattern` is a path glob rather than a shell command.
    PATH_TOOLS = %w[read_file write_file edit_file glob grep]

    def initialize(@tool : String, @pattern : String)
    end

    # A malformed entry yields nil rather than raising: a typo in a config
    # file must not stop smith from starting.
    def self.parse(str : String) : Rule?
      text = str.strip
      open = text.index('(')

      # A bare tool name is a rule about the whole tool — `mcp__filesystem__*`
      # is the form every MCP client writes, and there is nothing sensible to
      # put in parentheses for a tool whose arguments smith cannot interpret.
      return bare(text) if open.nil?
      return nil unless text.ends_with?(')')

      tool = text[0...open].strip
      # Take everything up to the *last* ')', so a pattern may contain its own
      # parentheses — `bash( echo $(date) )`.
      pattern = text[(open + 1)..-2].strip
      return nil if tool.empty? || pattern.empty?

      new(tool, pattern)
    end

    # `read_file` on its own would silently widen to `read_file(*)`, which is
    # not what anyone writing a path rule means. Two forms are unambiguous
    # enough to accept bare: anything carrying a wildcard, and any MCP tool —
    # smith cannot interpret a server's arguments, so its name is the only
    # thing a rule could ever match on.
    MCP_PREFIX = "mcp__"

    private def self.bare(text : String) : Rule?
      return nil if text.empty? || text.includes?(' ')
      return nil unless text.includes?('*') || text.starts_with?(MCP_PREFIX)

      new(text, "*")
    end

    def to_s(io : IO) : Nil
      if @pattern == "*" && (wildcard? || @tool.starts_with?(MCP_PREFIX))
        io << @tool
      else
        io << @tool << '(' << @pattern << ')'
      end
    end

    def path_tool? : Bool
      PATH_TOOLS.includes?(@tool)
    end

    # Whether the rule names a family of tools rather than one.
    def wildcard? : Bool
      @tool.includes?('*')
    end

    # `mcp__filesystem__*` covers every tool of that server. Anchored at both
    # ends, so `mcp__fs__read` cannot be matched by a rule meant for another
    # server whose name merely starts the same way.
    def covers?(tool_name : String) : Bool
      return @tool == tool_name unless wildcard?

      Regex.new("\\A#{Regex.escape(@tool).gsub("\\*", ".*")}\\z").matches?(tool_name)
    end

    # `all` distinguishes the two halves of shell-command matching, and the
    # distinction is security-critical:
    #
    #   allow  — *every* segment must match, so an allowed prefix cannot
    #            smuggle a second command in behind it
    #   deny   — *any* segment matching is enough, so a denied command cannot
    #            hide behind a harmless one
    def matches?(tool_name : String, args : JSON::Any, project_dir : String, all : Bool) : Bool
      return false unless covers?(tool_name)
      return true if @pattern == "*" || @pattern == "**"

      if path_tool?
        matches_path?(args, project_dir)
      elsif tool_name == "bash"
        matches_command?(args, all)
      else
        false
      end
    end

    private def matches_command?(args : JSON::Any, all : Bool) : Bool
      command = args["command"]?.try(&.as_s?)
      return false if command.nil?

      segments = AllowList.segments(command)
      return false if segments.empty?

      regex = self.class.command_regex(@pattern)
      all ? segments.all? { |s| regex.matches?(s) } : segments.any? { |s| regex.matches?(s) }
    end

    # Everything is escaped except `*`, which becomes `.*`. The trailing group
    # is what makes `bash(git status)` cover `git status --short` while still
    # rejecting `git statuses`.
    def self.command_regex(pattern : String) : Regex
      body = Regex.escape(pattern).gsub("\\*", ".*")
      Regex.new("\\A#{body}(?:\\s.*)?\\z")
    end

    private def matches_path?(args : JSON::Any, project_dir : String) : Bool
      raw = args["path"]?.try(&.as_s?) || args["pattern"]?.try(&.as_s?)
      # A tool call without a path (a project-wide grep) is only covered by the
      # bare wildcard, which was handled above.
      return false if raw.nil?

      File.match?(self.class.expand_pattern(@pattern, project_dir), Paths.normalize(raw, project_dir))
    end

    # A pattern starting with `**` stays unanchored, so `read_file(**/.ssh/**)`
    # can catch a key outside the project. Anything else relative is resolved
    # against the project directory.
    def self.expand_pattern(pattern : String, project_dir : String) : String
      return pattern if pattern.starts_with?("/") || pattern.starts_with?("**")
      # `home: true` is not optional here: without it Crystal leaves the `~`
      # in place and resolves the rest against the *current directory*, so
      # `deny = ["read_file(~/.ssh/**)"]` would expand to a path inside the
      # project and quietly match nothing at all.
      return File.expand_path(pattern, home: true) if pattern.starts_with?("~")

      File.join(project_dir, pattern)
    end
  end

  # Path normalisation, kept apart because getting it wrong is how a scoped
  # rule gets bypassed.
  module Paths
    # Collapses `..` and resolves symlinks. Both matter: without the first,
    # `write_file(src/../../../etc/passwd)` walks straight out of a
    # `write_file(src/**)` scope; without the second, a symlink inside the
    # scope does the same thing more quietly.
    #
    # The file need not exist — a write_file usually targets a new one — so the
    # deepest existing ancestor is resolved and the rest appended.
    def self.normalize(path : String, project_dir : String) : String
      absolute = File.expand_path(path, project_dir)
      resolve_existing_prefix(absolute)
    end

    private def self.resolve_existing_prefix(path : String) : String
      trailing = [] of String
      current = path

      loop do
        if File.exists?(current) || File.symlink?(current)
          resolved = begin
            File.realpath(current)
          rescue File::Error
            current
          end

          return trailing.empty? ? resolved : File.join([resolved] + trailing.reverse)
        end

        parent = File.dirname(current)
        break if parent == current

        trailing << File.basename(current)
        current = parent
      end

      path
    end
  end

  # The configured rules, consulted before anything is shown to the user.
  class RuleSet
    getter project_dir : String

    def self.build(
      allow : Array(String) = [] of String,
      ask : Array(String) = [] of String,
      deny : Array(String) = [] of String,
      project_dir : String = Dir.current,
      warn_io : IO = STDERR,
    ) : RuleSet
      new(
        parse(allow, warn_io),
        parse(ask, warn_io),
        parse(deny, warn_io),
        project_dir
      )
    end

    private def self.parse(entries : Array(String), warn_io : IO) : Array(Rule)
      entries.compact_map do |entry|
        rule = Rule.parse(entry)
        warn_io.puts "⚠️  Ignoring malformed permission rule: #{entry.inspect}" if rule.nil?
        rule
      end
    end

    def initialize(
      @allow : Array(Rule) = [] of Rule,
      @ask : Array(Rule) = [] of Rule,
      @deny : Array(Rule) = [] of Rule,
      project_dir : String = Dir.current,
    )
      # Normalised the same way the tool paths are. Without this, every
      # relative rule silently stops matching whenever the project is reached
      # through a symlink — and that is the common case, not an exotic one: on
      # macOS /tmp is a link to /private/tmp, and a shell's `cd` leaves
      # Dir.current unresolved.
      @project_dir = Paths.normalize(project_dir, project_dir)

      # Only deny and ask can stop a call, so only they decide whether a
      # non-mutating tool has to reach the gate at all.
      @governed = Set(String).new
      @governed_patterns = Array(Rule).new
      (@deny + @ask).each do |rule|
        rule.wildcard? ? @governed_patterns << rule : @governed << rule.tool
      end
    end

    def empty? : Bool
      @allow.empty? && @ask.empty? && @deny.empty?
    end

    # Whether a call to this tool could be stopped by a rule. Kept to a set
    # lookup so the common case — no rules for read tools — costs nothing.
    def governs?(tool_name : String) : Bool
      return true if @governed.includes?(tool_name)
      # Only consulted when the set missed, and only wildcard rules are in
      # here — so the common case is still a single hash lookup.
      @governed_patterns.any?(&.covers?(tool_name))
    end

    def decide(tool_name : String, args : JSON::Any) : Decision
      return Decision::Deny if any_match?(@deny, tool_name, args)
      return Decision::Ask if any_match?(@ask, tool_name, args)
      return Decision::Allow if @allow.any? { |rule| rule.matches?(tool_name, args, @project_dir, all: true) }

      Decision::Unset
    end

    private def any_match?(rules : Array(Rule), tool_name : String, args : JSON::Any) : Bool
      rules.any? { |rule| rule.matches?(tool_name, args, @project_dir, all: false) }
    end

    # Which deny rule stopped a call, so the model is told what to avoid.
    def matching_deny(tool_name : String, args : JSON::Any) : String?
      @deny.find { |rule| rule.matches?(tool_name, args, @project_dir, all: false) }.try(&.to_s)
    end

    # The narrowest rule worth offering behind [a]lways — narrower than "this
    # tool, everywhere", which is what the old prompt remembered.
    def suggest(tool_name : String, args : JSON::Any) : String
      # Before the path branch: an MCP tool may well take a `path` argument,
      # but no rule matches on it — offering `mcp__fs__read(src/**)` would
      # remember a rule that then covers every path.
      return tool_name if tool_name.starts_with?(Rule::MCP_PREFIX)

      if tool_name == "bash" && (command = args["command"]?.try(&.as_s?))
        words = command.strip.split(/\s+/)
        return "bash(#{words.size > 1 ? "#{words[0..-2].join(" ")} *" : words[0]})"
      end

      if (raw = args["path"]?.try(&.as_s?))
        directory = File.dirname(Paths.normalize(raw, @project_dir))
        relative = directory.lchop(@project_dir).lchop('/')
        return "#{tool_name}(#{relative.empty? ? "**" : "#{relative}/**"})"
      end

      "#{tool_name}(**)"
    end
  end
end
