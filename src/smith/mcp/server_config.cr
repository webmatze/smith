require "json"
require "uri"
require "../paths"

module Smith::MCP
  # One MCP server as `mcp.json` describes it. Two shapes:
  #
  # - **stdio**: a subprocess smith spawns (`command`, `args`, `env`)
  # - **Streamable HTTP**: a URL smith talks to (`url`, `headers`)
  #
  # `url` decides which: an entry with a url is an HTTP server, everything
  # else is a subprocess.
  struct ServerSpec
    getter name : String
    getter command : String?
    getter args : Array(String)
    getter env : Hash(String, String)
    getter url : String?
    getter headers : Hash(String, String)
    getter source : String

    def initialize(
      @name : String,
      @command : String? = nil,
      @args : Array(String) = Array(String).new,
      @env : Hash(String, String) = Hash(String, String).new,
      @url : String? = nil,
      @headers : Hash(String, String) = Hash(String, String).new,
      @source : String = "",
    )
    end

    def http? : Bool
      !@url.nil?
    end

    def stdio? : Bool
      !http?
    end

    # What smith starts or connects to — the line for `smith mcp list`.
    def description : String
      url = @url
      return url unless url.nil?

      ([@command || "?"] + @args).join(" ")
    end

    # The same, cut back to what identifies a server without carrying a
    # secret with it.
    #
    # Both halves of `description` are places a token is routinely written:
    # `--api-key X` is an ordinary way to configure a stdio server, and a url
    # can hide one in its userinfo, its path, its query or its fragment. The
    # server's own name, which is printed beside this, is what tells two
    # entries apart; the argument list only ever confirmed it.
    #
    # `env` and `headers` are not here at all — those are expanded from the
    # environment, which is where the keys live.
    def safe_description : String
      url = @url
      return ServerSpec.safe_url(url) unless url.nil?

      command = @command || "?"
      @args.empty? ? command : "#{command} (#{@args.size} argument#{@args.size == 1 ? "" : "s"})"
    end

    # Scheme, host and port. Everything else a url can carry is somewhere a
    # credential has been found before.
    def self.safe_url(url : String) : String
      uri = URI.parse(url)
      host = uri.host
      return "(url)" if host.nil? || host.empty?

      String.build do |str|
        str << uri.scheme << "://" if uri.scheme
        str << host
        str << ':' << uri.port if uri.port
      end
    rescue
      "(url)"
    end

    # Any url inside a message smith did not compose itself — an exception
    # from the HTTP client, a warning that quotes the config — cut back the
    # same way.
    def self.scrub_urls(text : String) : String
      text.gsub(/\b[a-zA-Z][a-zA-Z0-9+.\-]*:\/\/[^\s'"<>]+/) do |match|
        # A url runs up to whitespace, so the punctuation that ends the
        # sentence around it is part of the match. Handing that back keeps the
        # message readable — "at <url>: connection refused" rather than the
        # colon disappearing into the url.
        if tail = match.match(/^(.*?)([.,;:!?)\]}'"]+)$/)
          "#{safe_url(tail[1])}#{tail[2]}"
        else
          safe_url(match)
        end
      end
    end
  end

  # Discovery and parsing of `mcp.json`.
  #
  # Deliberately its own file rather than a section in `config.toml`: the
  # format below is the one every other MCP client reads, and keeping it
  # verbatim is what lets an existing configuration be copied across unchanged.
  #
  #   {"mcpServers": {"fs": {"command": "npx", "args": [...], "env": {...}}}}
  module ServerConfig
    FILE_NAME = "mcp.json"

    def self.global_path : String
      File.join(Smith.home_dir, FILE_NAME)
    end

    # Walks up from start_dir looking for .smith/mcp.json, stopping at the git
    # root — the same boundary Config.project_path uses, so running smith from
    # a subdirectory still finds the project's servers.
    def self.project_path(start_dir : String = Dir.current) : String?
      curr = File.expand_path(start_dir)

      loop do
        candidate = File.join(curr, ".smith", FILE_NAME)
        return candidate if File.exists?(candidate) && File.file?(candidate)

        break if Smith.git_root?(curr)
        parent = File.dirname(curr)
        break if parent == curr
        curr = parent
      end

      nil
    end

    # Global first, then project — a project entry of the same name replaces
    # the global one outright, the way every other config tier behaves.
    def self.discover(start_dir : String = Dir.current, warn_io : IO = STDERR) : Array(ServerSpec)
      merged = Hash(String, ServerSpec).new

      [global_path, project_path(start_dir)].each do |path|
        next if path.nil?
        parse_file(path, warn_io).each { |spec| merged[spec.name] = spec }
      end

      merged.values
    end

    def self.parse_file(path : String, warn_io : IO = STDERR) : Array(ServerSpec)
      return Array(ServerSpec).new unless File.exists?(path) && File.file?(path)

      begin
        parse(File.read(path), path, warn_io)
      rescue ex : File::Error
        warn_io.puts "⚠️  Could not read #{path}: #{ex.message}"
        Array(ServerSpec).new
      end
    end

    # A malformed file yields a warning and no servers. Never an exception: a
    # typo in mcp.json must not stop smith from starting.
    def self.parse(text : String, source : String = "mcp.json", warn_io : IO = STDERR) : Array(ServerSpec)
      specs = Array(ServerSpec).new

      json = begin
        JSON.parse(text)
      rescue ex : JSON::ParseException
        warn_io.puts "⚠️  Ignoring malformed MCP config at #{source}: #{ex.message}"
        return specs
      end

      root = json.as_h?
      return specs if root.nil?

      # `servers` is what a handful of clients write instead; reading both
      # costs one line and saves a confusing empty list.
      table = (root["mcpServers"]? || root["servers"]?).try(&.as_h?)
      if table.nil?
        warn_io.puts "⚠️  #{source} has no \"mcpServers\" object — no MCP servers loaded."
        return specs
      end

      table.each do |name, entry|
        spec = build(name, entry, source, warn_io)
        specs << spec if spec
      end

      specs
    end

    private def self.build(name : String, entry : JSON::Any, source : String, warn_io : IO) : ServerSpec?
      fields = entry.as_h?
      return nil if fields.nil?
      return nil if fields["disabled"]?.try(&.as_bool?)

      transport = (fields["type"]? || fields["transport"]?).try(&.as_s?)
      url = fields["url"]?.try(&.as_s?)

      case transport
      when Nil, "stdio"
        # An entry that has a url but no type is the HTTP shape several
        # clients write without saying "http" — the command branch below
        # stays the explicit one.
        return build_http(name, url, fields, source, warn_io) if transport.nil? && !url.nil?
      when "http", "sse", "streamable-http"
        return build_http(name, url, fields, source, warn_io)
      else
        warn_io.puts "⚠️  Skipping MCP server '#{name}' in #{source}: #{transport} transport is not supported (stdio and http)."
        return nil
      end

      command = fields["command"]?.try(&.as_s?)
      if command.nil? || command.strip.empty?
        warn_io.puts "⚠️  Skipping MCP server '#{name}' in #{source}: no \"command\"."
        return nil
      end

      ServerSpec.new(
        name: name,
        command: command,
        args: fields["args"]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || Array(String).new,
        env: string_map(fields["env"]?),
        source: source
      )
    end

    private def self.build_http(name : String, url : String?, fields : Hash(String, JSON::Any), source : String, warn_io : IO) : ServerSpec?
      if url.nil? || url.strip.empty?
        warn_io.puts "⚠️  Skipping MCP server '#{name}' in #{source}: no \"url\"."
        return nil
      end

      uri = URI.parse(url)
      unless uri.scheme.in?("http", "https")
        # Sanitised, not verbatim: this line reaches stderr at session start
        # and `smith doctor`'s output, and a rejected url is still a url that
        # may carry a token.
        warn_io.puts "⚠️  Skipping MCP server '#{name}' in #{source}: '#{ServerSpec.safe_url(url)}' is not an http(s) url."
        return nil
      end

      ServerSpec.new(
        name: name,
        url: url,
        headers: expand_headers(fields["headers"]?, name, warn_io),
        source: source
      )
    end

    # Header values may reference environment variables — `"Bearer ${TOKEN}"`
    # is the intended way to hand over a secret without writing it into the
    # file. An unset variable is named at startup rather than sent as `${TOKEN}`.
    private def self.expand_headers(value : JSON::Any?, server : String, warn_io : IO) : Hash(String, String)
      result = Hash(String, String).new
      table = value.try(&.as_h?)
      return result if table.nil?

      table.each do |key, entry|
        text = entry.as_s?
        next if text.nil?

        result[key] = text.gsub(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/) do |match|
          found = ENV[$1]?
          if found.nil?
            warn_io.puts "⚠️  MCP server '#{server}': header '#{key}' references #{match}, which is not set in the environment — sending it empty."
            ""
          else
            found
          end
        end
      end

      result
    end

    private def self.string_map(value : JSON::Any?) : Hash(String, String)
      result = Hash(String, String).new
      table = value.try(&.as_h?)
      return result if table.nil?

      table.each do |key, entry|
        # Numbers and booleans appear in real configs (ports, flags); they mean
        # the obvious thing as an environment variable.
        text = entry.as_s? || entry.raw.try(&.to_s)
        result[key] = text if text
      end

      result
    end
  end
end
