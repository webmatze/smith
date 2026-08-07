require "http/client"
require "json"
require "./provider"
require "./types"
require "./retry"
require "./anthropic_stream"

module Smith::LLM
  class Anthropic < Provider
    DEFAULT_ENDPOINT   = "https://api.anthropic.com/v1/messages"
    DEFAULT_MODEL      = "claude-sonnet-5"
    DEFAULT_MAX_TOKENS = 4096
    API_VERSION        = "2023-06-01"

    getter api_key : String
    getter default_model : String

    # Caching needs a minimum prefix length (1024 tokens on Sonnet/Opus, 2048
    # on Haiku); below that the 1.25x write surcharge buys nothing, hence the
    # switch.
    getter? cache : Bool

    def initialize(
      @api_key : String = ENV.fetch("ANTHROPIC_API_KEY", ""),
      @default_model : String = DEFAULT_MODEL,
      @timeouts : Timeouts = Timeouts.default,
      @cache : Bool = true,
    )
      if @api_key.empty?
        raise ArgumentError.new("Anthropic API key is missing. Set ANTHROPIC_API_KEY environment variable.")
      end
    end

    def name : String
      "anthropic"
    end

    def complete(request : Request) : Response
      model_to_use = request.model.empty? ? @default_model : request.model
      payload = build_payload(model_to_use, request)

      Retry.with_retry do
        send_request(payload)
      end
    end

    def complete_streaming(request : Request, &on_delta : String -> Nil) : Response
      return deliver_without_streaming(request, on_delta) unless request.stream?

      model_to_use = request.model.empty? ? @default_model : request.model
      payload = build_payload(model_to_use, request, streaming: true)
      emitted = false

      Retry.with_retry do
        begin
          headers = HTTP::Headers{
            "x-api-key"         => @api_key,
            "anthropic-version" => API_VERSION,
            "Content-Type"      => "application/json",
            "Accept"            => "text/event-stream",
          }

          stream_request(URI.parse(DEFAULT_ENDPOINT), headers, payload, "Anthropic") do |body_io|
            AnthropicStream.read(body_io, @default_model) do |chunk|
              emitted = true
              on_delta.call(chunk)
            end
          end
        rescue ex : Exception
          # Replaying now would print the already-visible text a second time.
          raise Retry::Fatal.new(ex) if emitted
          raise ex
        end
      end
    end

    private def build_payload(model : String, request : Request, streaming : Bool = false) : String
      String.build do |str|
        JSON.build(str) do |json|
          json.object do
            json.field "model", model
            json.field "max_tokens", request.max_tokens || DEFAULT_MAX_TOKENS
            json.field "stream", true if streaming

            if sys = request.system
              json.field "system" do
                if @cache
                  # cache_control needs the block form. System prompt and tool
                  # definitions are byte-identical for the whole session — the
                  # ideal prefix to cache, and otherwise paid for on every turn.
                  json.array do
                    json.object do
                      json.field "type", "text"
                      json.field "text", sys
                      cache_control(json)
                    end
                  end
                else
                  json.scalar sys
                end
              end
            end

            if temp = request.temperature
              json.field "temperature", temp
            end

            # Messages serialization
            breakpoint = @cache ? transcript_breakpoint(request.messages) : nil

            json.field "messages" do
              json.array do
                request.messages.each_with_index do |msg, index|
                  # System messages handled in top-level system field
                  next if msg.role.system?
                  serialize_message(json, msg, cache: index == breakpoint)
                end
              end
            end

            # Tools definition
            if tools = request.tools
              unless tools.empty?
                json.field "tools" do
                  json.array do
                    # Marking the last entry caches every tool before it, so
                    # the order must stay stable — Registry#specs relies on
                    # Hash preserving insertion order. Do not sort this.
                    tools.each_with_index do |tool, index|
                      json.object do
                        json.field "name", tool.name
                        json.field "description", tool.description
                        json.field "input_schema", tool.parameters
                        cache_control(json) if @cache && index == tools.size - 1
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    private def cache_control(json : JSON::Builder) : Nil
      json.field "cache_control" do
        json.object { json.field "type", "ephemeral" }
      end
    end

    # The index of the message to mark, or nil when there is nothing worth
    # marking yet.
    #
    # The *second-to-last* user turn, not the last: the newest one changes with
    # the next request, so a breakpoint there would write a cache nothing ever
    # reads. Tool results count — Anthropic receives them as user turns.
    #
    # Note this is invalidated whenever Context.compact rewrites the prefix.
    # That is unavoidable and correct; the system prompt and tools stay cached
    # either way.
    private def transcript_breakpoint(messages : Array(Message)) : Int32?
      user_turns = Array(Int32).new
      messages.each_with_index do |msg, index|
        user_turns << index if msg.role.user? || msg.role.tool?
      end
      return nil if user_turns.size < 2

      user_turns[-2]
    end

    private def serialize_message(json : JSON::Builder, msg : Message, cache : Bool = false)
      case msg.role
      when Role::User
        blocks = msg.content.select { |b| b.type.text? && b.text }

        json.object do
          json.field "role", "user"
          json.field "content" do
            json.array do
              blocks.each_with_index do |b, index|
                json.object do
                  json.field "type", "text"
                  json.field "text", b.text
                  cache_control(json) if cache && index == blocks.size - 1
                end
              end
            end
          end
        end
      when Role::Assistant
        json.object do
          json.field "role", "assistant"
          json.field "content" do
            json.array do
              msg.content.each do |b|
                case b.type
                when ContentBlock::BlockType::Text
                  if txt = b.text
                    json.object do
                      json.field "type", "text"
                      json.field "text", txt
                    end
                  end
                when ContentBlock::BlockType::ToolUse
                  json.object do
                    json.field "type", "tool_use"
                    json.field "id", b.tool_call_id
                    json.field "name", b.tool_name
                    json.field "input", b.tool_args || JSON.parse("{}")
                  end
                else
                  # skip
                end
              end
            end
          end
        end
      when Role::Tool
        # In Anthropic Messages API, tool results are sent under role "user"
        json.object do
          json.field "role", "user"
          json.field "content" do
            json.array do
              results = msg.content.select(&.type.tool_result?)
              results.each_with_index do |b, index|
                json.object do
                  json.field "type", "tool_result"
                  json.field "tool_use_id", b.tool_call_id
                  json.field "content", b.text || ""
                  if b.is_error
                    json.field "is_error", true
                  end
                  cache_control(json) if cache && index == results.size - 1
                end
              end
            end
          end
        end
      else
        # skip
      end
    end

    private def send_request(payload : String) : Response
      uri = URI.parse(DEFAULT_ENDPOINT)
      headers = HTTP::Headers{
        "x-api-key"         => @api_key,
        "anthropic-version" => API_VERSION,
        "Content-Type"      => "application/json",
      }

      client = build_client(uri)
      begin
        response = client.post(uri.path, headers: headers, body: payload)

        unless response.status_code == 200
          raise ResponseError.new(
            response.status_code,
            "Anthropic API request failed [#{response.status_code}]: #{response.body}"
          )
        end

        parse_response(response.body)
      ensure
        client.close
      end
    end

    private def parse_response(body : String) : Response
      json = JSON.parse(body)

      id = json["id"]?.try(&.as_s) || "anthropic-msg-#{Time.local.to_unix}"
      model = json["model"]?.try(&.as_s) || @default_model
      finish_reason = json["stop_reason"]?.try(&.as_s)

      blocks = Array(ContentBlock).new

      if content_arr = json["content"]?.try(&.as_a?)
        content_arr.each do |item|
          item_type = item["type"]?.try(&.as_s)
          case item_type
          when "text"
            if txt = item["text"]?.try(&.as_s)
              blocks << ContentBlock.text(txt)
            end
          when "tool_use"
            tu_id = item["id"].as_s
            tu_name = item["name"].as_s
            tu_input = item["input"]
            blocks << ContentBlock.tool_use(tu_id, tu_name, tu_input)
          end
        end
      end

      usage = nil
      if u = json["usage"]?
        prompt_tokens = u["input_tokens"]?.try(&.as_i) || 0
        completion_tokens = u["output_tokens"]?.try(&.as_i) || 0
        total_tokens = prompt_tokens + completion_tokens
        usage = Usage.new(
          prompt_tokens,
          completion_tokens,
          total_tokens,
          cache_creation_tokens: u["cache_creation_input_tokens"]?.try(&.as_i?) || 0,
          cache_read_tokens: u["cache_read_input_tokens"]?.try(&.as_i?) || 0
        )
      end

      Response.new(
        id: id,
        model: model,
        content: blocks,
        stop_reason: finish_reason,
        usage: usage
      )
    end
  end
end
