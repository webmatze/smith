require "toml"
require "./paths"

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

    DEFAULT_CONNECT_TIMEOUT    =  10
    DEFAULT_READ_TIMEOUT       = 120
    DEFAULT_APPROVAL_MODE      = "prompt"
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

    def initialize(@table : Hash(String, TOML::Any) = Hash(String, TOML::Any).new, @sources : Array(String) = Array(String).new)
    end

    # Reads the global config, then the nearest project config, and merges them
    # with the project file winning on conflicts.
    def self.load(start_dir : String = Dir.current) : Config
      table = Hash(String, TOML::Any).new
      sources = Array(String).new

      [global_path, project_path(start_dir)].each do |path|
        next unless path
        next unless parsed = parse_file(path)
        table = deep_merge(table, parsed)
        sources << path
      end

      new(table, sources)
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
