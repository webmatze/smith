require "http/client"
require "json"
require "./provider"
require "./types"
require "./retry"
require "./anthropic_stream"
require "./anthropic_caching"

module Smith::LLM
  class Anthropic < Provider
    include AnthropicCaching

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

    # The one provider that takes a PDF as a document block and reads it
    # itself, pages and all.
    def supports_documents? : Bool
      true
    end

    # A tool_result's content may be an array of blocks, images among them —
    # which is what lets `read_file` hand back a screenshot.
    def supports_tool_result_media? : Bool
      true
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
            AnthropicStream.read(body_io, @default_model, on_thinking: @on_thinking) do |chunk|
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
            max_tokens = request.max_tokens || DEFAULT_MAX_TOKENS

            json.field "model", model
            json.field "max_tokens", max_tokens
            json.field "stream", true if streaming

            if budget = request.thinking_budget
              # The legacy form, for models older than 4.6. The provider's own
              # error for an oversized budget reads as an opaque API complaint;
              # caught here it says what to change.
              if budget >= max_tokens
                raise ArgumentError.new(
                  "thinking budget (#{budget}) must be smaller than max_tokens (#{max_tokens}); " \
                  "raise max_tokens or lower [providers.anthropic] thinking_budget"
                )
              end

              json.field "thinking" do
                json.object do
                  json.field "type", "enabled"
                  json.field "budget_tokens", budget
                end
              end
            elsif effort = request.thinking_effort
              json.field "thinking" do
                json.object do
                  json.field "type", "adaptive"
                  # Without this the blocks arrive with empty text, and there
                  # would be nothing to show.
                  json.field "display", "summarized"
                end
              end

              json.field "output_config" do
                json.object do
                  json.field "effort", effort
                end
              end
            end

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

    # Images and PDFs take the same source object; only the block type around
    # it differs.
    private def base64_source(json : JSON::Builder, block : ContentBlock)
      json.object do
        json.field "type", "base64"
        json.field "media_type", block.media_type
        json.field "data", block.data
      end
    end

    private def serialize_message(json : JSON::Builder, msg : Message, cache : Bool = false)
      case msg.role
      when Role::User
        # Attachments sit between text blocks in the order the user wrote
        # them, so a prompt that says "compare @before.png with @after.png"
        # still says which is which.
        blocks = msg.content.select { |b| (b.type.text? && b.text) || (b.media? && b.data) }

        json.object do
          json.field "role", "user"
          json.field "content" do
            json.array do
              blocks.each_with_index do |b, index|
                last = cache && index == blocks.size - 1

                case b.type
                when ContentBlock::BlockType::Image
                  json.object do
                    json.field "type", "image"
                    json.field "source" do
                      base64_source(json, b)
                    end
                    cache_control(json) if last
                  end
                when ContentBlock::BlockType::Document
                  json.object do
                    json.field "type", "document"
                    json.field "source" do
                      base64_source(json, b)
                    end
                    cache_control(json) if last
                  end
                else
                  json.object do
                    json.field "type", "text"
                    json.field "text", b.text
                    cache_control(json) if last
                  end
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
                when ContentBlock::BlockType::Thinking
                  json.object do
                    json.field "type", "thinking"
                    json.field "thinking", b.text || ""
                    # Byte for byte: an altered signature makes the whole
                    # request invalid.
                    json.field "signature", b.signature if b.signature
                  end
                when ContentBlock::BlockType::RedactedThinking
                  json.object do
                    json.field "type", "redacted_thinking"
                    json.field "data", b.text || ""
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

              # Attachments travel as siblings of the result they belong to
              # and are folded back in here, by call id. This is the only
              # place that knows about the nesting.
              media = msg.content.select { |b| b.media? && b.data }
                .group_by { |b| b.tool_call_id }

              results.each_with_index do |b, index|
                attached = media[b.tool_call_id]?

                json.object do
                  json.field "type", "tool_result"
                  json.field "tool_use_id", b.tool_call_id
                  json.field "content" do
                    if attached
                      json.array do
                        json.object do
                          json.field "type", "text"
                          json.field "text", b.text || ""
                        end

                        attached.each do |m|
                          json.object do
                            json.field "type", m.type.image? ? "image" : "document"
                            json.field "source" do
                              base64_source(json, m)
                            end
                          end
                        end
                      end
                    else
                      # The string form, byte for byte as before. Reshaping a
                      # text-only result into an array would invalidate the
                      # prompt cache of every session already running.
                      json.scalar b.text || ""
                    end
                  end
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
          when "thinking"
            blocks << ContentBlock.thinking(
              item["thinking"]?.try(&.as_s?) || "",
              item["signature"]?.try(&.as_s?)
            )
          when "redacted_thinking"
            blocks << ContentBlock.redacted_thinking(item["data"]?.try(&.as_s?) || "")
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
