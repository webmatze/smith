require "toml"
require "digest/sha256"
require "./paths"
require "./mode"
require "./hooks"
require "./subagents"
require "./mentions"

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
    DEFAULT_CACHE       = true

    DEFAULT_CONNECT_TIMEOUT    =  10
    DEFAULT_READ_TIMEOUT       = 120
    DEFAULT_APPROVAL_MODE      = "prompt"
    DEFAULT_MODE               = "normal"
    DEFAULT_MAX_CONTEXT_TOKENS = 120_000

    DEFAULT_THINKING         = false
    DEFAULT_THINKING_EFFORT  = "medium"
    DEFAULT_REASONING_EFFORT = "none"

    DEFAULT_WEB_ALLOW_PRIVATE = false
    DEFAULT_WEB_MAX_BYTES     = 256 * 1024
    DEFAULT_SEARCH_PROVIDER   = "none"
    DEFAULT_SEARXNG_HOST      = "http://localhost:8888"

    DEFAULT_BASH_TIMEOUT        = 120
    DEFAULT_MAX_BACKGROUND_JOBS =  10
    DEFAULT_MAX_OUTPUT_BYTES    = 256 * 1024

    DEFAULT_CHECKPOINTS_ENABLED = true
    DEFAULT_MAX_CHECKPOINTS     = 100
    DEFAULT_RETENTION_DAYS      =  30

    struct HTTPSettings
      getter connect_timeout : Int32
      getter read_timeout : Int32

      def initialize(@connect_timeout : Int32, @read_timeout : Int32)
      end
    end

    struct ApprovalSettings
      getter mode : String
      getter allowlist : Array(String)
      getter allow : Array(String)
      getter ask : Array(String)
      getter deny : Array(String)

      def initialize(
        @mode : String,
        @allowlist : Array(String),
        @allow : Array(String) = Array(String).new,
        @ask : Array(String) = Array(String).new,
        @deny : Array(String) = Array(String).new,
      )
      end
    end

    struct WebSettings
      getter allow_private : Bool
      getter max_bytes : Int32
      getter search_provider : String
      getter searxng_host : String

      def initialize(@allow_private : Bool, @max_bytes : Int32, @search_provider : String, @searxng_host : String)
      end
    end

    struct BashSettings
      getter timeout : Int32
      getter max_background_jobs : Int32
      getter max_output_bytes : Int32

      def initialize(@timeout : Int32, @max_background_jobs : Int32, @max_output_bytes : Int32)
      end
    end

    struct CheckpointSettings
      getter? enabled : Bool
      getter max_per_session : Int32
      getter retention_days : Int32

      def initialize(@enabled : Bool, @max_per_session : Int32, @retention_days : Int32)
      end

      def retention : Time::Span
        @retention_days.days
      end
    end

    struct SubagentSettings
      getter max_depth : Int32
      getter max_children : Int32

      def initialize(@max_depth : Int32, @max_children : Int32)
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
    @allowlist_deprecated : Bool? = nil

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

    # Anthropic prompt caching. On by default; worth switching off only when
    # the prompt is too short to reach the cache minimum.
    def cache_for(provider_name : String) : Bool
      value = lookup("providers", provider_name, "cache").try(&.as_bool?)
      value.nil? ? DEFAULT_CACHE : value
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
      allowlist = string_list("approval", "allowlist")

      # The old bash-only allowlist keeps working, expressed in the new
      # syntax. It stays in `allowlist` too, so PromptApprover's existing
      # matching is untouched.
      unless allowlist.empty?
        @allowlist_deprecated ||= begin
          STDERR.puts "⚠️  [approval] allowlist is deprecated; use allow = [\"bash(<command>)\"] instead."
          true
        end
      end

      ApprovalSettings.new(
        mode: lookup("approval", "mode").try(&.as_s?) || DEFAULT_APPROVAL_MODE,
        allowlist: allowlist,
        allow: string_list("approval", "allow") + allowlist.map { |entry| "bash(#{entry})" },
        ask: string_list("approval", "ask"),
        deny: string_list("approval", "deny")
      )
    end

    private def string_list(*keys : String) : Array(String)
      lookup(*keys).try(&.as_a?).try(&.compact_map(&.as_s?)) || Array(String).new
    end

    # Budgets for @-mentions. allow_outside is off by default: a prompt coming
    # from a skill file could otherwise pull in ~/.ssh/id_rsa.
    def mentions : Mentions::Settings
      Mentions::Settings.new(
        max_lines: lookup("mentions", "max_lines").try(&.as_i?) || Mentions::DEFAULT_MAX_LINES,
        max_total_bytes: lookup("mentions", "max_total_bytes").try(&.as_i?) || Mentions::DEFAULT_MAX_TOTAL_BYTES,
        allow_outside: lookup("mentions", "allow_outside").try(&.as_bool?) || false
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

    # Extended thinking is off by default: it costs tokens, and only Anthropic
    # supports it in the form smith implements.
    def thinking? : Bool
      value = lookup("defaults", "thinking").try(&.as_bool?)
      value.nil? ? DEFAULT_THINKING : value
    end

    # How deep to think: low | medium | high | xhigh | max.
    def thinking_effort : String
      lookup("providers", "anthropic", "thinking_effort").try(&.as_s?) || DEFAULT_THINKING_EFFORT
    end

    # Only for Anthropic models older than 4.6, which take a token budget
    # instead of an effort level. Unset on purpose: current models reject it.
    def thinking_budget : Int32?
      lookup("providers", "anthropic", "thinking_budget").try(&.as_i?)
    end

    # Was hardcoded in the OpenAI adapter.
    def reasoning_effort : String
      lookup("providers", "openai", "reasoning_effort").try(&.as_s?) || DEFAULT_REASONING_EFFORT
    end

    # Consumed by Tools::WebFetch and Tools::WebSearch via CLI#build_agent.
    # API keys are not here — they stay in the environment, like every other key.
    def web : WebSettings
      allow_private = lookup("web", "allow_private").try(&.as_bool?)

      WebSettings.new(
        allow_private: allow_private.nil? ? DEFAULT_WEB_ALLOW_PRIVATE : allow_private,
        max_bytes: lookup("web", "max_bytes").try(&.as_i?) || DEFAULT_WEB_MAX_BYTES,
        search_provider: lookup("web", "search_provider").try(&.as_s?) || DEFAULT_SEARCH_PROVIDER,
        searxng_host: lookup("web", "searxng_host").try(&.as_s?) || DEFAULT_SEARXNG_HOST
      )
    end

    # Consumed by Tools::Bash and Tools::BashJobs via CLI#build_agent.
    def bash : BashSettings
      BashSettings.new(
        timeout: lookup("bash", "timeout").try(&.as_i?) || DEFAULT_BASH_TIMEOUT,
        max_background_jobs: lookup("bash", "max_background_jobs").try(&.as_i?) || DEFAULT_MAX_BACKGROUND_JOBS,
        max_output_bytes: lookup("bash", "max_output_bytes").try(&.as_i?) || DEFAULT_MAX_OUTPUT_BYTES
      )
    end

    # Consumed by Checkpoints::Store via CLI#build_agent.
    def checkpoints : CheckpointSettings
      enabled = lookup("checkpoints", "enabled").try(&.as_bool?)

      CheckpointSettings.new(
        enabled: enabled.nil? ? DEFAULT_CHECKPOINTS_ENABLED : enabled,
        max_per_session: lookup("checkpoints", "max_per_session").try(&.as_i?) || DEFAULT_MAX_CHECKPOINTS,
        retention_days: lookup("checkpoints", "retention_days").try(&.as_i?) || DEFAULT_RETENTION_DAYS
      )
    end

    # Consumed by Subagents::Supervisor via CLI#build_agent. max_children = 0
    # switches subagents off entirely — the agent tool is then not registered.
    def subagents : SubagentSettings
      SubagentSettings.new(
        max_depth: lookup("subagents", "max_depth").try(&.as_i?) || Subagents::Supervisor::MAX_DEPTH,
        max_children: lookup("subagents", "max_children").try(&.as_i?) || Subagents::Supervisor::MAX_CHILDREN_PER_SESSION
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
