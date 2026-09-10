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
    #
    # What this does *not* cover: the command path itself, which is printed in
    # full and on purpose, because it is what identifies the server once the
    # arguments are gone. Someone who writes a secret into a path has written
    # it into a filename, and there is nothing left to tell two servers apart
    # by if that goes too.
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
    #
    # A url filter, and only that. It does nothing to text that is not
    # url-shaped, so it is not a general redactor and must not be treated as
    # one: text that could carry anything — a server's stderr, an HTTP error
    # body — has to be kept out of a message rather than run through this.
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
        env: expand_env(fields["env"]?, name, warn_io),
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

        result[key] = expand_vars(text, server, "header '#{key}'", warn_io)
      end

      result
    end

    # The same for a stdio server's `env`, because the reason is the same one:
    # a secret belongs in the environment and not in a file that gets
    # committed. Until this, `headers` understood `${VAR}` and `env` two
    # methods away did not, so the only ways to give a child process a token
    # were to write it in plainly or to leave it to inherit smith's entire
    # environment — the second of which is what #109 exists to stop, and
    # cannot be stopped while there is no other way to pass one deliberately.
    private def self.expand_env(value : JSON::Any?, server : String, warn_io : IO) : Hash(String, String)
      result = Hash(String, String).new
      table = value.try(&.as_h?)
      return result if table.nil?

      table.each do |key, entry|
        # Numbers and booleans appear in real configs (ports, flags); they mean
        # the obvious thing as an environment variable. Only a string is
        # expanded, because only a string can hold a `${VAR}` to begin with:
        # `8080` is a port, not a reference to anything.
        if text = entry.as_s?
          result[key] = expand_vars(text, server, "env '#{key}'", warn_io)
        elsif raw = entry.raw.try(&.to_s)
          result[key] = raw
        end
      end

      result
    end

    # One implementation for both, so a `${VAR}` cannot come to mean two
    # different things depending on which half of an entry it was written in.
    #
    # `what` names the place rather than the kind, because a header and an env
    # entry are both `key: value` and which one it was is the first thing
    # somebody reading the warning needs to know.
    # An unset variable becomes empty rather than being dropped, which the
    # issue asked for and which is worth a note, because the two halves are
    # not equally harmless. An empty header is inert. An empty *environment
    # variable* is not the same thing as an absent one to the program reading
    # it: an empty `PYTHONPATH` puts the working directory on the import path,
    # an empty `PATH` or `HOME` is a different program than no `PATH` or
    # `HOME`.
    #
    # The warning is the whole defence, and there is nothing behind it: an
    # explicit entry *overrides* what the child would have inherited, so an
    # empty expansion does not fall back to the inherited value, it replaces
    # it. `clear_env` will not change that — what `clear_env` takes away is
    # the fallback for a variable no entry names at all, which is a different
    # hazard. This one is already as sharp as it is going to get.
    #
    # If it is ever traded the other way, the alternative is cheap and worth
    # not rediscovering: `Process` reads a nil value as "leave this variable
    # unset", so dropping the key costs widening `ServerSpec#env` to
    # `Hash(String, String?)` and nothing else — `spawn_server` passes the map
    # straight through.
    #
    # There is no escape: a value that wants a literal `${NAME}` cannot have
    # one, `$$` and a backslash included. Inherited from headers rather than
    # decided here, and it matters more for `env`, where a value is likelier
    # to be a template some other program means to expand itself.
    private def self.expand_vars(text : String, server : String, what : String, warn_io : IO) : String
      text.gsub(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/) do |match|
        found = ENV[$1]?
        if found.nil?
          warn_io.puts "⚠️  MCP server '#{server}': #{what} references #{match}, which is not set in the environment — using an empty value."
          ""
        else
          found
        end
      end
    end
  end
end
