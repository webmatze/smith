require "http/client"
require "json"
require "./provider"
require "./types"
require "./retry"

module Smith::LLM
  class OpenRouter < Provider
    DEFAULT_SITE_URL = "https://github.com/webmatze/smith"
    DEFAULT_APP_NAME = "smith"
    DEFAULT_ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"

    getter api_key : String
    getter default_model : String

    def initialize(
      @api_key : String = ENV.fetch("OPENROUTER_API_KEY", ""),
      @default_model : String = "qwen/qwen3.8-max",
      @timeouts : Timeouts = Timeouts.default,
    )
      if @api_key.empty?
        raise ArgumentError.new("OpenRouter API key is missing. Set OPENROUTER_API_KEY environment variable.")
      end
    end

    def name : String
      "openrouter"
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

            if max_tok = request.max_tokens
              json.field "max_tokens", max_tok
            end

            if temp = request.temperature
              json.field "temperature", temp
            end

            json.field "messages" do
              json.array do
                # System prompt block if provided
                if sys = request.system
                  json.object do
                    json.field "role", "system"
                    json.field "content", sys
                  end
                end

                # Messages translation
                request.messages.each do |msg|
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
                        json.field "type", "function"
                        json.field "function" do
                          json.object do
                            json.field "name", tool.name
                            json.field "description", tool.description
                            json.field "parameters", tool.parameters
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
      end
    end

    private def serialize_message(json : JSON::Builder, msg : Message)
      case msg.role
      when Role::User
        text_content = msg.content.select { |b| b.type.text? }.map(&.text).compact.join("\n")
        json.object do
          json.field "role", "user"
          json.field "content", text_content
        end
      when Role::Assistant
        tool_uses = msg.content.select { |b| b.type.tool_use? }
        text_content = msg.content.select { |b| b.type.text? }.map(&.text).compact.join("\n")

        json.object do
          json.field "role", "assistant"
          json.field "content", text_content.empty? ? nil : text_content

          unless tool_uses.empty?
            json.field "tool_calls" do
              json.array do
                tool_uses.each do |tu|
                  json.object do
                    json.field "id", tu.tool_call_id
                    json.field "type", "function"
                    json.field "function" do
                      json.object do
                        json.field "name", tu.tool_name
                        json.field "arguments", tu.tool_args.to_json
                      end
                    end
                  end
                end
              end
            end
          end
        end
      when Role::Tool
        msg.content.each do |block|
          next unless block.type.tool_result?
          json.object do
            json.field "role", "tool"
            json.field "tool_call_id", block.tool_call_id
            json.field "content", block.text || ""
          end
        end
      else
        # System messages handled separately
      end
    end

    private def send_request(payload : String) : Response
      uri = URI.parse(DEFAULT_ENDPOINT)
      headers = HTTP::Headers{
        "Authorization" => "Bearer #{@api_key}",
        "HTTP-Referer"  => DEFAULT_SITE_URL,
        "X-Title"       => DEFAULT_APP_NAME,
        "Content-Type"  => "application/json",
      }

      client = build_client(uri)
      begin
        response = client.post(uri.path, headers: headers, body: payload)

        unless response.status_code == 200
          raise ResponseError.new(
            response.status_code,
            "OpenRouter API request failed [#{response.status_code}]: #{response.body}"
          )
        end

        parse_response(response.body)
      ensure
        client.close
      end
    end

    private def parse_response(body : String) : Response
      json = JSON.parse(body)

      id = json["id"]?.try(&.as_s) || "openrouter-gen-#{Time.local.to_unix}"
      model = json["model"]?.try(&.as_s) || @default_model

      choice = json["choices"][0]
      finish_reason = choice["finish_reason"]?.try(&.as_s)
      message_json = choice["message"]

      blocks = Array(ContentBlock).new

      if content_str = message_json["content"]?.try(&.as_s?)
        unless content_str.empty?
          blocks << ContentBlock.text(content_str)
        end
      end

      if tool_calls = message_json["tool_calls"]?.try(&.as_a?)
        tool_calls.each do |tc|
          tc_id = tc["id"].as_s
          fn = tc["function"]
          fn_name = fn["name"].as_s
          args_str = fn["arguments"].as_s
          args_json = JSON.parse(args_str)

          blocks << ContentBlock.tool_use(tc_id, fn_name, args_json)
        end
      end

      usage = nil
      if u = json["usage"]?
        prompt_tokens = u["prompt_tokens"]?.try(&.as_i) || 0
        completion_tokens = u["completion_tokens"]?.try(&.as_i) || 0
        total_tokens = u["total_tokens"]?.try(&.as_i) || 0
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
