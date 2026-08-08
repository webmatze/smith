require "json"
require "../paths"

module Smith::MCP
  # One stdio server as `mcp.json` describes it.
  struct ServerSpec
    getter name : String
    getter command : String
    getter args : Array(String)
    getter env : Hash(String, String)
    getter source : String

    def initialize(
      @name : String,
      @command : String,
      @args : Array(String) = Array(String).new,
      @env : Hash(String, String) = Hash(String, String).new,
      @source : String = "",
    )
    end

    def command_line : String
      ([@command] + @args).join(" ")
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

        break if Dir.exists?(File.join(curr, ".git"))
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

      # Stage 1 is stdio only. A remote server is skipped with a word about
      # why, which beats a start failure nobody can interpret.
      transport = (fields["type"]? || fields["transport"]?).try(&.as_s?)
      if transport && transport != "stdio"
        warn_io.puts "⚠️  Skipping MCP server '#{name}' in #{source}: #{transport} transport is not supported yet (stdio only)."
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
