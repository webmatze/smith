require "./protocol"
require "./client"
require "./http_transport"
require "./server_config"

module Smith::MCP
  # The lifecycle of one server: start it, keep it, restart it once if it dies,
  # then give up on it.
  #
  # The give-up is deliberate. A server that crashes twice is broken, and
  # retrying it on every call would turn every turn into a restart loop —
  # slower than having no tool at all, and far harder to read from a transcript.
  class ServerHandle
    getter spec : ServerSpec

    # The sanitised server name, as it appears in `mcp__<server>__<tool>`.
    getter name : String

    getter tools : Array(ToolDefinition)
    getter error : String?

    # The same failure without the server's own stderr and without whatever
    # stands in its argument list or its url beyond the host.
    #
    # A stdio server inherits smith's environment, so what it prints is not
    # smith's to repeat where the output is meant to be pasted into a bug
    # report. `error` keeps both for `smith mcp list`, where "why will this
    # not start" is the whole question and the server's own complaint is the
    # answer; `smith doctor` reads this one.
    getter error_summary : String?

    getter? lost : Bool

    # Wired by whoever registered the tools, so they can be withdrawn when the
    # server is given up on. The manager knows the registry; this file does not.
    property on_lost : Proc(ServerHandle, Nil)?

    @client : Client?
    @transport : Transport?
    @restarted = false

    def initialize(
      @spec : ServerSpec,
      @name : String,
      @timeout : Time::Span = Client::DEFAULT_TIMEOUT,
      @startup_timeout : Time::Span = Client::STARTUP_TIMEOUT,
      @grace : Time::Span = StdioTransport::GRACE,
    )
      @tools = Array(ToolDefinition).new
      @lost = false
    end

    def running? : Bool
      !@client.nil? && !@lost
    end

    # False rather than raising: one server that will not start must never
    # take the session with it.
    def start : Bool
      connect
      true
    rescue ex : Exception
      @error = failure_message(ex, @spec.description, with_stderr: true)
      @error_summary = failure_message(ex, @spec.safe_description, with_stderr: false)
      stop_client
      false
    end

    def call(tool : String, arguments : JSON::Any) : ToolResult
      client = @client
      raise ConnectionError.new("MCP server '#{@name}' is not running") if client.nil?

      begin
        client.call_tool(tool, arguments)
      rescue ex : ConnectionError
        retry_once(tool, arguments, ex)
      end
    end

    def stop : Nil
      stop_client
      @tools = Array(ToolDefinition).new
    end

    # The server's own stderr, kept so a failed handshake can say what the
    # process actually complained about.
    def stderr_tail : Array(String)
      @transport.try(&.stderr_tail) || Array(String).new
    end

    private def connect : Nil
      transport = build_transport
      @transport = transport

      client = Client.new(@name, transport, @timeout, @startup_timeout)
      begin
        client.start
      rescue ex
        client.close
        raise ex
      end

      @client = client
      @tools = client.tools
      @error = nil
    end

    # stdio spawns a subprocess; http connects to a url. Everything after this
    # — handshake, tools/list, restart-once — is the same for both.
    private def build_transport : Transport
      if url = @spec.url
        HttpTransport.new(URI.parse(url), @spec.headers, @timeout)
      else
        StdioTransport.spawn_server(@spec.command.not_nil!, @spec.args, @spec.env, grace: @grace)
      end
    end

    # One restart, then the tools go away. The retried call is the one the
    # model already asked for, so a server that merely fell over between turns
    # costs nothing visible.
    private def retry_once(tool : String, arguments : JSON::Any, cause : ConnectionError) : ToolResult
      if @restarted
        lose!("MCP server '#{@name}' died again after a restart — its tools have been withdrawn.")
        raise cause
      end

      @restarted = true
      stop_client

      begin
        connect
      rescue ex : Exception
        lose!(
          "MCP server '#{@name}' could not be restarted: #{failure_message(ex, @spec.description, with_stderr: true)}",
          "MCP server '#{@name}' could not be restarted: #{failure_message(ex, @spec.safe_description, with_stderr: false)}"
        )
        raise cause
      end

      client = @client
      raise cause if client.nil?

      begin
        client.call_tool(tool, arguments)
      rescue ex : ConnectionError
        # The replacement died on the very call it was started for. Waiting
        # for a *later* call to notice would leave a tool on offer that has
        # already proved it cannot work.
        lose!("MCP server '#{@name}' died again right after a restart — its tools have been withdrawn.")
        raise ex
      end
    end

    # `summary` defaults to `reason` because most of these are composed from
    # the server's name alone — there is then nothing in them to leave out.
    # The one that wraps a failure message passes both.
    private def lose!(reason : String, summary : String = reason) : Nil
      return if @lost
      @lost = true
      @error = reason
      @error_summary = summary
      stop_client
      @on_lost.try &.call(self)
    end

    private def stop_client : Nil
      @client.try &.close
      @client = nil
      @transport.try &.close
    end

    private def failure_message(ex : Exception, what : String, with_stderr : Bool) : String
      base = case ex
             when File::NotFoundError then "command not found: #{what}"
             when TimeoutError        then "no response to the MCP handshake — is #{what} an MCP server?"
             else                          ex.message || ex.class.name
             end

      # `ex.message` quotes the url too, so the sanitised form has to be put
      # back over it rather than only used for the messages built here.
      return ServerSpec.scrub_urls(base) unless with_stderr

      tail = stderr_tail.last(3).map(&.strip).reject(&.empty?)
      tail.empty? ? base : "#{base} (stderr: #{tail.join(" / ")})"
    end
  end

  # Every configured server, and the naming rules that keep their tools apart.
  class Manager
    # Anthropic and OpenAI both cap tool names at 64 characters and accept only
    # this alphabet, so a server called "my server!" has to be folded into it
    # before it ever reaches a request.
    MAX_TOOL_NAME = 64

    getter handles : Array(ServerHandle)

    def initialize(@handles : Array(ServerHandle) = Array(ServerHandle).new)
    end

    def self.build(
      specs : Array(ServerSpec),
      timeout : Time::Span = Client::DEFAULT_TIMEOUT,
      startup_timeout : Time::Span = Client::STARTUP_TIMEOUT,
      grace : Time::Span = StdioTransport::GRACE,
    ) : Manager
      taken = Set(String).new

      handles = specs.map do |spec|
        # Two servers whose names differ only in characters that get folded
        # away would otherwise export tools under the same prefix.
        name = unique(sanitize(spec.name), taken)
        ServerHandle.new(spec, name, timeout, startup_timeout, grace)
      end

      new(handles)
    end

    def empty? : Bool
      @handles.empty?
    end

    # Starts everything, reporting failures rather than raising them.
    def start_all(warn_io : IO = STDERR) : Nil
      @handles.each do |handle|
        next if handle.start

        warn_io.puts "⚠️  MCP server '#{handle.name}' did not start: #{handle.error}"
        warn_io.puts "   Its tools are unavailable; the session continues without them."
      end
    end

    def running : Array(ServerHandle)
      @handles.select(&.running?)
    end

    def shutdown : Nil
      @handles.each(&.stop)
    end

    # "filesystem (12 tools)" per running server, for the banner and `mcp list`.
    def summary : Array(String)
      running.map { |handle| "#{handle.name} (#{handle.tools.size} tool#{handle.tools.size == 1 ? "" : "s"})" }
    end

    def [](name : String) : ServerHandle?
      @handles.find { |handle| handle.name == name || handle.spec.name == name }
    end

    # The registered name for one tool. The `mcp__` prefix is what keeps these
    # clear of the built-in tools and makes `mcp__filesystem__*` addressable in
    # a permission rule.
    def self.tool_name(server : String, tool : String) : String
      prefix = "mcp__#{sanitize(server)}__"
      sanitized = sanitize(tool)

      # Truncating the tool half rather than the server half keeps the part a
      # permission rule matches on intact.
      room = MAX_TOOL_NAME - prefix.size
      sanitized = sanitized[0, room] if room > 0 && sanitized.size > room

      "#{prefix}#{sanitized}"
    end

    def self.sanitize(value : String) : String
      cleaned = value.gsub(/[^a-zA-Z0-9_-]/, "_")
      cleaned.empty? ? "server" : cleaned
    end

    def self.unique(name : String, taken : Set(String)) : String
      return name if taken.add?(name)

      counter = 2
      loop do
        candidate = "#{name}_#{counter}"
        return candidate if taken.add?(candidate)
        counter += 1
      end
    end
  end
end
