require "http/client"
require "json"
require "uri"
require "./version"
require "./paths"
require "./config"
require "./project_ctx"
require "./sandbox"
require "./mcp"

module Smith
  # What `smith doctor` knows about a setup, and how it found out.
  #
  # Two layers, kept apart on purpose. The checks below are pure functions of
  # plain data — they decide `ok | warn | fail` and write the lines a user
  # reads, and a spec can drive every branch of them without a network, a
  # subprocess or a home directory. `Runner` is the only part that touches the
  # outside world, and every probe it runs carries its own deadline.
  #
  # No provider is ever constructed here. `CLI#build_provider` calls
  # `require_api_key`, which exits on a missing key — and reporting a missing
  # key is this command's entire job, so the environment is read directly and
  # only ever for whether a variable is set.
  module Doctor
    enum Status
      Ok
      Warn
      Fail

      def marker : String
        case self
        in Ok   then "✅"
        in Warn then "⚠️ "
        in Fail then "❌"
        end
      end

      def label : String
        case self
        in Ok   then "ok"
        in Warn then "warn"
        in Fail then "fail"
        end
      end
    end

    struct Check
      getter title : String
      getter status : Status
      getter details : Array(String)

      def initialize(@title : String, @status : Status, @details : Array(String) = Array(String).new)
      end
    end

    struct Report
      getter checks : Array(Check)

      def initialize(@checks : Array(Check) = Array(Check).new)
      end

      def count(status : Status) : Int32
        @checks.count { |check| check.status == status }
      end

      def failed? : Bool
        @checks.any? { |check| check.status.fail? }
      end

      # A warning is worth reading, not worth failing a script over: only a
      # `fail` changes the exit code.
      def exit_code : Int32
        failed? ? 1 : 0
      end
    end

    # Every key smith reads, and the provider it belongs to. Keys stay
    # env-only — the same rule `Config` follows for the same reason.
    PROVIDER_KEYS = {
      "openrouter" => "OPENROUTER_API_KEY",
      "anthropic"  => "ANTHROPIC_API_KEY",
      "openai"     => "OPENAI_API_KEY",
    }

    SEARCH_KEYS = {
      "brave"  => "BRAVE_API_KEY",
      "tavily" => "TAVILY_API_KEY",
    }

    # Listing every pulled model would bury the rest of the report.
    MAX_LISTED_MODELS = 10

    # --- What the probes come back with ------------------------------------

    struct OllamaProbe
      getter models : Array(String)
      getter error : String?

      def initialize(@models : Array(String) = Array(String).new, @error : String? = nil)
      end

      def reachable? : Bool
        @error.nil?
      end
    end

    struct McpServerProbe
      getter name : String
      getter kind : String
      getter target : String
      getter tools : Int32
      getter error : String?

      def initialize(@name : String, @kind : String, @target : String, @tools : Int32 = 0, @error : String? = nil)
      end

      def ok? : Bool
        @error.nil?
      end
    end

    struct McpProbe
      getter sources : Array(String)
      getter servers : Array(McpServerProbe)
      getter warnings : Array(String)
      getter? enabled : Bool

      def initialize(
        @sources : Array(String) = Array(String).new,
        @servers : Array(McpServerProbe) = Array(McpServerProbe).new,
        @warnings : Array(String) = Array(String).new,
        @enabled : Bool = true,
      )
      end
    end

    # --- The checks --------------------------------------------------------

    # `present` says set or missing per variable and carries nothing else, so
    # no key value can reach this layer, let alone the output.
    def self.provider_check(present : Hash(String, Bool), active : String) : Check
      details = Array(String).new

      PROVIDER_KEYS.each do |provider, var|
        details << "#{label_for(provider, active)}: #{var} #{present[var]? ? "set" : "missing"}"
      end
      details << "#{label_for("ollama", active)}: no API key needed"

      known = Config::BUILTIN_MODELS.keys
      unless known.includes?(active)
        details << "'#{active}' is not a provider smith knows: #{known.join(", ")}"
        return Check.new("Provider", Status::Fail, details)
      end

      var = PROVIDER_KEYS[active]?
      if var && !present[var]?
        details << "export #{var}=… before starting a session, or pick another provider with -p."
        return Check.new("Provider", Status::Fail, details)
      end

      Check.new("Provider", Status::Ok, details)
    end

    private def self.label_for(provider : String, active : String) : String
      provider == active ? "#{provider} (in use)" : provider
    end

    # `candidates` are the config files that exist on disk; anything that did
    # not also end up in `sources` was malformed or unreadable, and `Config`
    # carries on without it rather than failing the run.
    def self.config_check(
      sources : Array(String),
      candidates : Array(String),
      provider : String,
      model : String,
      mode : String,
    ) : Check
      details = Array(String).new

      if sources.empty?
        details << "no config.toml loaded — the built-in defaults are in effect"
      else
        sources.each { |path| details << "loaded: #{path}" }
      end

      details << "[defaults] provider: #{provider}"
      details << "[defaults] model: #{model}"
      details << "[defaults] mode: #{mode}"

      ignored = candidates - sources
      ignored.each { |path| details << "ignored, unreadable or malformed: #{path}" }

      Check.new("Config", ignored.empty? ? Status::Ok : Status::Warn, details)
    end

    # `configured` means the user pointed smith at an Ollama somewhere. An
    # Ollama nobody asked for being absent is not a finding; one that is the
    # provider in use and absent is the reason the next session would fail.
    def self.ollama_check(host : String, probe : OllamaProbe, active : Bool, configured : Bool) : Check
      details = ["host: #{host}"]

      if error = probe.error
        details << error
        return Check.new("Ollama", Status::Fail, details) if active

        details << "not the provider in use — start it with `ollama serve` if you want it." if configured
        return Check.new("Ollama", configured ? Status::Warn : Status::Ok, details)
      end

      if probe.models.empty?
        details << "reachable, but no models are pulled — `ollama pull <model>`"
        return Check.new("Ollama", active ? Status::Fail : Status::Warn, details)
      end

      listed = probe.models.first(MAX_LISTED_MODELS)
      rest = probe.models.size - listed.size
      details << "#{probe.models.size} model#{probe.models.size == 1 ? "" : "s"}: " \
                 "#{listed.join(", ")}#{rest > 0 ? " (+#{rest} more)" : ""}"

      Check.new("Ollama", Status::Ok, details)
    end

    def self.mcp_check(probe : McpProbe) : Check
      return Check.new("MCP", Status::Ok, ["switched off ([mcp] enabled = false)"]) unless probe.enabled?

      details = Array(String).new

      if probe.sources.empty?
        details << "no #{MCP::ServerConfig::FILE_NAME} found — no MCP servers configured"
      else
        probe.sources.each { |path| details << "config: #{path}" }
      end

      details.concat(probe.warnings)

      probe.servers.each do |server|
        details << if error = server.error
          "#{server.name} (#{server.kind}) ✗ #{error} — #{server.target}"
        else
          "#{server.name} (#{server.kind}) ✓ #{server.tools} tool#{server.tools == 1 ? "" : "s"} — #{server.target}"
        end
      end

      broken = probe.servers.count { |server| !server.ok? }
      status = if broken > 0
                 Status::Fail
               elsif probe.warnings.empty?
                 Status::Ok
               else
                 Status::Warn
               end

      Check.new("MCP", status, details)
    end

    # Only which backend is configured and whether its key is set — searching
    # from a diagnostic would spend the user's quota to learn nothing more.
    def self.web_search_check(backend : String, present : Hash(String, Bool), searxng_host : String) : Check
      kind = backend.strip.downcase

      case kind
      when "none", ""
        Check.new("web_search", Status::Ok, ["off ([web] search_provider = \"none\") — the tool is not registered"])
      when "searxng"
        Check.new("web_search", Status::Ok, ["backend: searxng", "host: #{searxng_host}", "no API key needed"])
      when "brave", "tavily"
        var = SEARCH_KEYS[kind]
        if present[var]?
          Check.new("web_search", Status::Ok, ["backend: #{kind}", "#{var}: set"])
        else
          Check.new("web_search", Status::Fail, [
            "backend: #{kind}",
            "#{var}: missing",
            "web_search is registered, so every search fails until it is set.",
          ])
        end
      else
        Check.new("web_search", Status::Fail, [
          "backend: #{backend}",
          "not a backend smith knows: #{(SEARCH_KEYS.keys + ["searxng", "none"]).join(", ")}",
          "web_search is not registered at all.",
        ])
      end
    end

    # A sandbox that was asked for and is not in force is worth an exit code
    # either way: with `required = true` bash refuses to run, without it bash
    # runs with full rights while the config says otherwise.
    def self.sandbox_check(enabled : Bool, required : Bool, describe : String, probe : Sandbox::Probe) : Check
      details = ["configured: #{describe}", "trial run: #{probe.detail}"]

      unless enabled
        details << "set [sandbox] enabled = true to confine bash."
        return Check.new("Sandbox", Status::Ok, details)
      end

      return Check.new("Sandbox", Status::Ok, details) if probe.usable?

      details << (required ? "[sandbox] required = true, so bash will refuse to run." : "bash runs with your full rights.")
      Check.new("Sandbox", Status::Fail, details)
    end

    def self.environment_check(
      home : String,
      home_overridden : Bool,
      global_instructions : String?,
      project_instructions : Array(String),
      skills : Int32,
      agents : Int32,
    ) : Check
      details = [
        "version: smith #{Smith::VERSION}",
        "home: #{home}#{home_overridden ? " (SMITH_HOME override)" : ""}",
      ]

      details << "global instructions: #{global_instructions || "none in #{home}"}"

      if project_instructions.empty?
        details << "project instructions: none (#{ProjectContext::FILE_NAMES.join(" / ")})"
      else
        project_instructions.each { |path| details << "project instructions: #{path}" }
      end

      details << "skills: #{skills}"
      details << "agents: #{agents}"

      Check.new("Environment", Status::Ok, details)
    end

    # --- Rendering ---------------------------------------------------------

    def self.render(report : Report, io : IO) : Nil
      io.puts "🩺 smith doctor"

      report.checks.each do |check|
        io.puts
        io.puts "#{check.status.marker} #{check.title} — #{check.status.label}"
        check.details.each { |line| io.puts "   #{line}" }
      end

      io.puts
      io.puts "#{report.count(Status::Ok)} ok, #{report.count(Status::Warn)} warn, #{report.count(Status::Fail)} fail"
      io.puts "A warning does not change the exit code; a failure does." if report.failed?
    end

    # --- The probes, and the deadlines that bound them ---------------------

    OLLAMA_CONNECT_TIMEOUT = 2.seconds
    OLLAMA_READ_TIMEOUT    = 2.seconds

    # Per server. `Client::STARTUP_TIMEOUT` is 10 s, which is right for a
    # session that then runs for an hour and far too long for a diagnostic
    # that promises to be quick.
    MCP_STARTUP_TIMEOUT = 3.seconds

    # For all servers together. They are probed in parallel, so this is a
    # wall-clock cap and not a per-server one.
    MCP_DEADLINE = 5.seconds

    # The whole gather. Every probe runs in its own fiber, so what a machine
    # where nothing answers costs is the longest probe, not their sum.
    DEADLINE = 6.seconds

    def self.env_keys : Hash(String, Bool)
      (PROVIDER_KEYS.values + SEARCH_KEYS.values).to_h do |var|
        # Whether, never what. A value that is not read cannot be printed.
        {var, !ENV[var]?.presence.nil?}
      end
    end

    def self.probe_ollama(host : String) : OllamaProbe
      uri = URI.parse("#{host.chomp("/")}/api/tags")
      client = HTTP::Client.new(uri)
      client.connect_timeout = OLLAMA_CONNECT_TIMEOUT
      client.read_timeout = OLLAMA_READ_TIMEOUT
      # Crystal honours this on Windows only. Everywhere else `getaddrinfo`
      # runs on the thread, so a resolver that hangs blocks every fiber and
      # the deadline in `Runner#gather` cannot fire either — the one path
      # through this command that nothing bounds.
      client.dns_timeout = OLLAMA_CONNECT_TIMEOUT

      begin
        response = client.get(uri.request_target)
        return OllamaProbe.new(error: "HTTP #{response.status_code} from #{uri}") unless response.status.success?

        OllamaProbe.new(models: parse_models(response.body))
      ensure
        client.close
      end
    rescue ex : Exception
      OllamaProbe.new(error: "not reachable: #{ex.message.presence || ex.class.name}")
    end

    private def self.parse_models(body : String) : Array(String)
      JSON.parse(body)["models"]?.try(&.as_a?)
        .try(&.compact_map { |entry| entry["name"]?.try(&.as_s?) }) || Array(String).new
    rescue
      Array(String).new
    end

    # A real handshake, the same one a session performs, against a manager of
    # our own: `CLI#mcp_manager` starts its servers sequentially with the long
    # session timeouts, and it is the session's manager, not a diagnostic's.
    def self.probe_mcp(config : Config, start_dir : String = Dir.current) : McpProbe
      settings = config.mcp
      sources = [MCP::ServerConfig.global_path, MCP::ServerConfig.project_path(start_dir)]
        .compact
        .select { |path| File.exists?(path) && File.file?(path) }

      return McpProbe.new(sources: sources, enabled: false) unless settings.enabled?

      notices = IO::Memory.new
      specs = MCP::ServerConfig.discover(start_dir, warn_io: notices)
      warnings = notices.to_s.lines.map(&.strip).reject(&.empty?)

      manager = MCP::Manager.build(specs, timeout: MCP_STARTUP_TIMEOUT, startup_timeout: MCP_STARTUP_TIMEOUT)

      begin
        McpProbe.new(sources: sources, servers: probe_servers(manager), warnings: warnings)
      ensure
        # Nothing a probe started may outlive it — the same contract the
        # session keeps for its own servers.
        manager.shutdown
      end
    end

    private def self.probe_servers(manager : MCP::Manager) : Array(McpServerProbe)
      handles = manager.handles
      return Array(McpServerProbe).new if handles.empty?

      # Buffered to the full count, so a fiber that answers after the deadline
      # never blocks on a collector that has already stopped listening.
      inbox = Channel(McpServerProbe).new(handles.size)

      handles.each do |handle|
        spawn do
          probe = begin
            if handle.start
              McpServerProbe.new(handle.name, kind(handle.spec), target(handle.spec), handle.tools.size)
            else
              McpServerProbe.new(handle.name, kind(handle.spec), target(handle.spec), error: redact(handle.error || "did not start", handle.spec))
            end
          rescue ex : Exception
            McpServerProbe.new(handle.name, kind(handle.spec), target(handle.spec), error: redact(ex.message.presence || ex.class.name, handle.spec))
          end

          inbox.send(probe)
        end
      end

      answered = Hash(String, McpServerProbe).new
      deadline = Time.instant + MCP_DEADLINE

      handles.size.times do
        remaining = deadline - Time.instant
        break if remaining <= Time::Span.zero

        select
        when probe = inbox.receive
          answered[probe.name] = probe
        when timeout(remaining)
          break
        end
      end

      handles.map do |handle|
        answered[handle.name]? || McpServerProbe.new(
          handle.name, kind(handle.spec), target(handle.spec),
          error: "no answer within #{MCP_DEADLINE.total_seconds.round.to_i}s"
        )
      end
    end

    private def self.kind(spec : MCP::ServerSpec) : String
      spec.http? ? "http" : "stdio"
    end

    # `ServerHandle` quotes what it tried to reach when it explains a failure,
    # and for an http server that is the url out of mcp.json — query string
    # and whatever is in it included. A diagnostic is the last place that
    # should be echoed, so the same trimmed url goes in instead.
    private def self.redact(message : String, spec : MCP::ServerSpec) : String
      url = spec.url
      return message if url.nil?

      message.gsub(url, target(spec))
    end

    # What `smith mcp list` shows, minus a url's query string. `env` and
    # `headers` are never printed at all: headers are expanded from the
    # environment, which is where the tokens are.
    private def self.target(spec : MCP::ServerSpec) : String
      url = spec.url
      return spec.description if url.nil?

      uri = URI.parse(url)
      uri.query = nil
      uri.to_s
    rescue
      "(url)"
    end

    # --- Gathering ---------------------------------------------------------

    alias OllamaProbeFn = Proc(String, OllamaProbe)
    alias McpProbeFn = Proc(McpProbe)
    alias SandboxProbeFn = Proc(Sandbox::Probe)

    # Everything the report needs, with the three probes that leave the
    # process injectable — so the specs can drive every path of `run` offline,
    # and a developer's own keys or their running Ollama can never decide
    # whether the suite passes.
    class Runner
      def initialize(
        @config : Config,
        @provider : String,
        @model : String,
        @mode : String,
        @skills : Int32,
        @agents : Int32,
        @start_dir : String = Dir.current,
        @keys : Hash(String, Bool) = Doctor.env_keys,
        @ollama_probe : OllamaProbeFn = ->(host : String) { Doctor.probe_ollama(host) },
        @mcp_probe : McpProbeFn? = nil,
        @sandbox_probe : SandboxProbeFn = -> { Smith::Sandbox.probe },
      )
      end

      def run : Report
        ollama, mcp, sandbox = gather

        sandbox_settings = @config.sandbox
        web = @config.web

        Report.new([
          Doctor.provider_check(@keys, @provider),
          Doctor.config_check(@config.sources, config_candidates, @provider, @model, @mode),
          Doctor.ollama_check(@config.ollama_host, ollama, @provider == "ollama", ollama_configured?),
          Doctor.mcp_check(mcp),
          Doctor.web_search_check(web.search_provider, @keys, web.searxng_host),
          Doctor.sandbox_check(
            sandbox_settings.enabled?,
            sandbox_settings.required?,
            Sandbox.build(sandbox_settings.policy, @start_dir).describe,
            sandbox
          ),
          Doctor.environment_check(
            Smith.home_dir,
            !ENV["SMITH_HOME"]?.presence.nil?,
            ProjectContext.global_file,
            ProjectContext.project_files(@start_dir),
            @skills,
            @agents
          ),
        ])
      end

      # The three probes run together under one wall-clock deadline. A fiber
      # that is still stuck when it expires is abandoned rather than waited
      # for: the answer it would give is "did not answer", which is the answer
      # already recorded.
      private def gather : {OllamaProbe, McpProbe, Sandbox::Probe}
        inbox = Channel(OllamaProbe | McpProbe | Sandbox::Probe).new(3)
        host = @config.ollama_host
        mcp_probe = @mcp_probe || -> { Doctor.probe_mcp(@config, @start_dir) }

        spawn do
          inbox.send(begin
            @ollama_probe.call(host)
          rescue ex : Exception
            OllamaProbe.new(error: "probe failed: #{ex.message.presence || ex.class.name}")
          end)
        end

        spawn do
          inbox.send(begin
            mcp_probe.call
          rescue ex : Exception
            McpProbe.new(warnings: ["probe failed: #{ex.message.presence || ex.class.name}"])
          end)
        end

        spawn do
          inbox.send(begin
            @sandbox_probe.call
          rescue ex : Exception
            Sandbox::Probe.new(Sandbox::Availability::Blocked, "probe failed: #{ex.message.presence || ex.class.name}")
          end)
        end

        ollama : OllamaProbe? = nil
        mcp : McpProbe? = nil
        sandbox : Sandbox::Probe? = nil
        deadline = Time.instant + DEADLINE

        3.times do
          remaining = deadline - Time.instant
          break if remaining <= Time::Span.zero

          select
          when value = inbox.receive
            case value
            in OllamaProbe    then ollama = value
            in McpProbe       then mcp = value
            in Sandbox::Probe then sandbox = value
            end
          when timeout(remaining)
            break
          end
        end

        seconds = DEADLINE.total_seconds.round.to_i

        {
          ollama || OllamaProbe.new(error: "no answer within #{seconds}s"),
          mcp || McpProbe.new(warnings: ["the MCP probe did not finish within #{seconds}s"]),
          sandbox || Sandbox::Probe.new(Sandbox::Availability::Blocked, "no answer within #{seconds}s"),
        }
      end

      # Both files a run would read, whether or not they parsed.
      private def config_candidates : Array(String)
        [Config.global_path, Config.project_path(@start_dir)]
          .compact
          .select { |path| File.exists?(path) && File.file?(path) }
      end

      # Whether anyone pointed smith at an Ollama, as opposed to the built-in
      # localhost default nobody chose.
      private def ollama_configured? : Bool
        !ENV["OLLAMA_HOST"]?.presence.nil? || @config.ollama_host != Config::DEFAULT_OLLAMA_HOST
      end
    end
  end
end
