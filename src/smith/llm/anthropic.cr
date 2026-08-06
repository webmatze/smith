require "http/client"
require "json"
require "./provider"
require "./types"
require "./retry"

module Smith::LLM
  class Anthropic < Provider
    DEFAULT_ENDPOINT   = "https://api.anthropic.com/v1/messages"
    DEFAULT_MODEL      = "claude-sonnet-5"
    DEFAULT_MAX_TOKENS = 4096
    API_VERSION        = "2023-06-01"

    getter api_key : String
    getter default_model : String

    def initialize(
      @api_key : String = ENV.fetch("ANTHROPIC_API_KEY", ""),
      @default_model : String = DEFAULT_MODEL,
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

    private def build_payload(model : String, request : Request) : String
      String.build do |str|
        JSON.build(str) do |json|
          json.object do
            json.field "model", model
            json.field "max_tokens", request.max_tokens || DEFAULT_MAX_TOKENS

            if sys = request.system
              json.field "system", sys
            end

            if temp = request.temperature
              json.field "temperature", temp
            end

            # Messages serialization
            json.field "messages" do
              json.array do
                request.messages.each do |msg|
                  # System messages handled in top-level system field
                  next if msg.role.system?
                  serialize_message(json, msg)
                end
              end
            end

            # Tools definition
            if tools = request.tools
              unless tools.empty?
                json.field "tools" do
                  json.array do
                    tools.each do |tool|
                      json.object do
                        json.field "name", tool.name
                        json.field "description", tool.description
                        json.field "input_schema", tool.parameters
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

    private def serialize_message(json : JSON::Builder, msg : Message)
      case msg.role
      when Role::User
        json.object do
          json.field "role", "user"
          json.field "content" do
            json.array do
              msg.content.each do |b|
                if b.type.text? && (txt = b.text)
                  json.object do
                    json.field "type", "text"
                    json.field "text", txt
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
              msg.content.each do |b|
                next unless b.type.tool_result?
                json.object do
                  json.field "type", "tool_result"
                  json.field "tool_use_id", b.tool_call_id
                  json.field "content", b.text || ""
                  if b.is_error
                    json.field "is_error", true
                  end
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

      client = HTTP::Client.new(uri)
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
        usage = Usage.new(prompt_tokens, completion_tokens, total_tokens)
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
