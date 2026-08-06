require "http/client"
require "json"
require "./provider"
require "./types"
require "./retry"

module Smith::LLM
  class Ollama < Provider
    DEFAULT_HOST  = "http://localhost:11434"
    DEFAULT_MODEL = "gemma4:latest"

    getter host : String
    getter default_model : String

    def initialize(
      host : String? = nil,
      @default_model : String = DEFAULT_MODEL,
    )
      raw_host = host || ENV.fetch("OLLAMA_HOST", DEFAULT_HOST)
      # Normalize host URL
      @host = raw_host.ends_with?("/") ? raw_host.chomp("/") : raw_host
    end

    def name : String
      "ollama"
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
            json.field "stream", false

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
      endpoint_url = "#{@host}/v1/chat/completions"
      uri = URI.parse(endpoint_url)
      headers = HTTP::Headers{
        "Content-Type" => "application/json",
      }

      begin
        client = HTTP::Client.new(uri)
        begin
          response = client.post(uri.path, headers: headers, body: payload)

          unless response.status_code == 200
            raise ResponseError.new(
              response.status_code,
              "Ollama API request failed [#{response.status_code}]: #{response.body}"
            )
          end

          parse_response(response.body)
        ensure
          client.close
        end
      rescue ex : Socket::ConnectError | Socket::Error
        raise ResponseError.new(
          503,
          "Failed to connect to Ollama at #{@host}. Make sure Ollama service is running (`ollama serve`)."
        )
      end
    end

    private def parse_response(body : String) : Response
      json = JSON.parse(body)

      id = json["id"]?.try(&.as_s) || "ollama-gen-#{Time.local.to_unix}"
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
          tc_id = tc["id"]?.try(&.as_s) || "call_#{Random::Secure.hex(4)}"
          fn = tc["function"]
          fn_name = fn["name"].as_s
          args_raw = fn["arguments"]

          args_json = if args_raw.as_s?
                        JSON.parse(args_raw.as_s)
                      else
                        args_raw
                      end

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
