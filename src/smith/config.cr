require "toml"
require "digest/sha256"
require "./paths"
require "./mode"
require "./hooks"

module Smith
  # Resolved configuration, merged from (lowest to highest priority):
  #
  #   built-in defaults  <  global config  <  project config  <  env var  <  CLI flag
  #
  # The CLI flag tier lives in `Smith::CLI` — it simply skips asking the Config
  # when a flag was supplied. Everything below that is resolved here.
  #
  # API keys are deliberately *not* read from the config file. They stay
  # env-only so a plaintext config never becomes a place secrets get committed
  # from.
  class Config
    CONFIG_FILE_NAME = "config.toml"

    DEFAULT_PROVIDER = "openrouter"

    BUILTIN_MODELS = {
      "openrouter" => "qwen/qwen3.8-max",
      "ollama"     => "gemma4:latest",
      "anthropic"  => "claude-sonnet-5",
      "openai"     => "gpt-5.6-luna",
    }

    DEFAULT_MODEL       = BUILTIN_MODELS[DEFAULT_PROVIDER]
    DEFAULT_OLLAMA_HOST = "http://localhost:11434"
    DEFAULT_STREAM      = true

    DEFAULT_CONNECT_TIMEOUT    =  10
    DEFAULT_READ_TIMEOUT       = 120
    DEFAULT_APPROVAL_MODE      = "prompt"
    DEFAULT_MODE               = "normal"
    DEFAULT_MAX_CONTEXT_TOKENS = 120_000

    struct HTTPSettings
      getter connect_timeout : Int32
      getter read_timeout : Int32

      def initialize(@connect_timeout : Int32, @read_timeout : Int32)
      end
    end

    struct ApprovalSettings
      getter mode : String
      getter allowlist : Array(String)

      def initialize(@mode : String, @allowlist : Array(String))
      end
    end

    struct ContextSettings
      getter max_tokens : Int32

      def initialize(@max_tokens : Int32)
      end
    end

    # Config files that were actually read, lowest priority first. Useful for
    # diagnostics ("why is smith using this model?").
    getter sources : Array(String)

    @table : Hash(String, TOML::Any)

    # Hook sections are kept per origin rather than read out of the merged
    # table, for two reasons: deep_merge replaces arrays, so merging would drop
    # the global hooks; and a *project* config that defines hooks is arbitrary
    # code from whoever wrote the repo, which needs a trust decision that
    # global hooks do not.
    @global_hooks : TOML::Any?
    @project_hooks : TOML::Any?

    def initialize(
      @table : Hash(String, TOML::Any) = Hash(String, TOML::Any).new,
      @sources : Array(String) = Array(String).new,
      @global_hooks : TOML::Any? = nil,
      @project_hooks : TOML::Any? = nil,
    )
    end

    # Reads the global config, then the nearest project config, and merges them
    # with the project file winning on conflicts.
    def self.load(start_dir : String = Dir.current) : Config
      table = Hash(String, TOML::Any).new
      sources = Array(String).new
      global_hooks = nil
      project_hooks = nil
      project = project_path(start_dir)

      [global_path, project].each do |path|
        next unless path
        next unless parsed = parse_file(path)
        table = deep_merge(table, parsed)
        sources << path

        if path == project
          project_hooks = parsed["hooks"]?
        else
          global_hooks = parsed["hooks"]?
        end
      end

      new(table, sources, global_hooks, project_hooks)
    end

    def self.global_path : String
      File.join(Smith.home_dir, CONFIG_FILE_NAME)
    end

    # Walks up from start_dir looking for .smith/config.toml, stopping at the
    # git root — same boundary ProjectContext.discover uses, so running smith
    # from a subdirectory still finds the project's config. Nearest wins.
    def self.project_path(start_dir : String = Dir.current) : String?
      curr = File.expand_path(start_dir)

      loop do
        candidate = File.join(curr, ".smith", CONFIG_FILE_NAME)
        return candidate if File.exists?(candidate) && File.file?(candidate)

        break if Dir.exists?(File.join(curr, ".git"))
        parent = File.dirname(curr)
        break if parent == curr
        curr = parent
      end

      nil
    end

    # A broken config file must never take smith down — warn and carry on with
    # whatever the other tiers provide.
    private def self.parse_file(path : String) : Hash(String, TOML::Any)?
      return nil unless File.exists?(path) && File.file?(path)

      begin
        TOML.parse(File.read(path))
      rescue ex : TOML::ParseException
        STDERR.puts "⚠️  Ignoring malformed config at #{path}: #{ex.message}"
        nil
      rescue ex : File::Error
        STDERR.puts "⚠️  Could not read config at #{path}: #{ex.message}"
        nil
      end
    end

    private def self.deep_merge(base : Hash(String, TOML::Any), over : Hash(String, TOML::Any)) : Hash(String, TOML::Any)
      merged = base.dup

      over.each do |key, value|
        existing = merged[key]?
        existing_hash = existing.try(&.as_h?)
        value_hash = value.as_h?

        merged[key] = if existing_hash && value_hash
                        TOML::Any.new(deep_merge(existing_hash, value_hash))
                      else
                        value
                      end
      end

      merged
    end

    def provider : String
      env("SMITH_PROVIDER") ||
        lookup("defaults", "provider").try(&.as_s?) ||
        DEFAULT_PROVIDER
    end

    def stream? : Bool
      value = lookup("defaults", "stream").try(&.as_bool?)
      value.nil? ? DEFAULT_STREAM : value
    end

    # Consumed by CLI#effective_mode, below the --plan flag.
    def mode : Mode
      Mode.from_string(
        env("SMITH_MODE") ||
        lookup("defaults", "mode").try(&.as_s?) ||
        DEFAULT_MODE
      )
    end

    def model_for(provider_name : String) : String
      env("SMITH_MODEL") ||
        lookup("providers", provider_name, "model").try(&.as_s?) ||
        BUILTIN_MODELS[provider_name]? ||
        DEFAULT_MODEL
    end

    def ollama_host : String
      env("OLLAMA_HOST") ||
        lookup("providers", "ollama", "host").try(&.as_s?) ||
        DEFAULT_OLLAMA_HOST
    end

    # Consumed by issue #4 (HTTP timeouts).
    def http : HTTPSettings
      HTTPSettings.new(
        connect_timeout: lookup("http", "connect_timeout").try(&.as_i?) || DEFAULT_CONNECT_TIMEOUT,
        read_timeout: lookup("http", "read_timeout").try(&.as_i?) || DEFAULT_READ_TIMEOUT
      )
    end

    # Consumed by Tools::Approver via CLI#build_approver.
    def approval : ApprovalSettings
      allowlist = lookup("approval", "allowlist").try(&.as_a?)
        .try(&.compact_map(&.as_s?)) || Array(String).new

      ApprovalSettings.new(
        mode: lookup("approval", "mode").try(&.as_s?) || DEFAULT_APPROVAL_MODE,
        allowlist: allowlist
      )
    end

    # Consumed by issue #3 (history compaction).
    def context : ContextSettings
      ContextSettings.new(
        max_tokens: lookup("context", "max_tokens").try(&.as_i?) || DEFAULT_MAX_CONTEXT_TOKENS
      )
    end

    # Hooks run arbitrary commands with the user's rights, so a project config
    # that defines them has to be trusted once. nil means the project config
    # defines no hooks at all; the digest changes whenever they do.
    def project_hooks_digest : String?
      hooks = @project_hooks
      return nil if hooks.nil?

      # TOML::Any renders its raw value; parse order follows file order, so
      # the same file always yields the same digest.
      Digest::SHA256.hexdigest(hooks.to_s)
    end

    # Global first, then project — the order hooks fire in.
    def hooks : Array(Hooks::Definition)
      global_hooks + parse_hooks(@project_hooks)
    end

    # Everything except the project config's hooks. Used when the user has not
    # trusted this project: their own global hooks still run.
    def global_hooks : Array(Hooks::Definition)
      parse_hooks(@global_hooks)
    end

    private def parse_hooks(section : TOML::Any?) : Array(Hooks::Definition)
      definitions = Array(Hooks::Definition).new
      table = section.try(&.as_h?)
      return definitions if table.nil?

      table.each do |key, entries|
        event = Hooks::Event.from_key(key)
        next if event.nil?

        entries.as_a?.try &.each do |entry|
          definition = build_hook(event, entry)
          definitions << definition if definition
        end
      end

      definitions
    end

    # A malformed hook is skipped rather than raised on: a broken entry in a
    # config file must not be able to stop smith from starting.
    private def build_hook(event : Hooks::Event, entry : TOML::Any) : Hooks::Definition?
      fields = entry.as_h?
      return nil if fields.nil?

      command = fields["command"]?.try(&.as_s?)
      return nil if command.nil? || command.strip.empty?

      matcher = fields["matcher"]?.try(&.as_s?).try do |pattern|
        begin
          Regex.new(pattern)
        rescue ArgumentError
          STDERR.puts "⚠️  Ignoring hook '#{command}': invalid matcher #{pattern.inspect}"
          return nil
        end
      end

      Hooks::Definition.new(
        event: event,
        command: command,
        matcher: matcher,
        timeout: fields["timeout"]?.try(&.as_i?) || Hooks::DEFAULT_TIMEOUT,
        once: fields["once"]?.try(&.as_bool?) || false
      )
    end

    # Navigates the merged table. Any missing or wrongly-typed level yields nil
    # so the caller falls through to the next priority tier.
    private def lookup(*keys : String) : TOML::Any?
      current : TOML::Any? = nil

      keys.each_with_index do |key, index|
        current = if index.zero?
                    @table[key]?
                  else
                    current.try(&.as_h?).try(&.[key]?)
                  end
        return nil if current.nil?
      end

      current
    end

    private def env(name : String) : String?
      value = ENV[name]?
      return nil if value.nil? || value.empty?
      value
    end
  end
end
