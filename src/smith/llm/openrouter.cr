require "http/client"
require "json"
require "./provider"
require "./types"
require "./openai_content"
require "./retry"
require "./sse"
require "./anthropic_caching"

module Smith::LLM
  class OpenRouter < Provider
    include AnthropicCaching

    DEFAULT_SITE_URL = "https://github.com/webmatze/smith"
    DEFAULT_APP_NAME = "smith"
    DEFAULT_ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"

    # OpenRouter model ids for Anthropic models all carry this prefix, and it
    # is the whole capability test — no metadata call, no model table.
    ANTHROPIC_PREFIX = "anthropic/"

    getter api_key : String
    getter default_model : String

    # Prompt caching, and only reachable on an `anthropic/` route. On by
    # default like the direct Anthropic provider: on any other route the
    # markers are a verified no-op — OpenRouter answers 200 and ignores them —
    # so leaving it on costs nothing.
    getter? cache : Bool

    def initialize(
      @api_key : String = ENV.fetch("OPENROUTER_API_KEY", ""),
      @default_model : String = "qwen/qwen3.8-max",
      @timeouts : Timeouts = Timeouts.default,
      @cache : Bool = true,
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

    def complete_streaming(request : Request, &on_delta : String -> Nil) : Response
      return deliver_without_streaming(request, on_delta) unless request.stream?

      model_to_use = request.model.empty? ? @default_model : request.model
      payload = build_payload(model_to_use, request, streaming: true)
      emitted = false

      Retry.with_retry do
        begin
          stream_request(URI.parse(DEFAULT_ENDPOINT), stream_headers, payload, "OpenRouter") do |body_io|
            OpenAIStream.read(body_io, @default_model, cache_usage: cache_route?(model_to_use)) do |chunk|
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

    private def stream_headers : HTTP::Headers
      HTTP::Headers{
        "Authorization" => "Bearer #{@api_key}",
        "HTTP-Referer"  => DEFAULT_SITE_URL,
        "X-Title"       => DEFAULT_APP_NAME,
        "Content-Type"  => "application/json",
        "Accept"        => "text/event-stream",
      }
    end

    # Whether this request goes somewhere the cache markers mean anything.
    # OpenRouter hands them to Anthropic and drops them everywhere else, so a
    # false positive costs nothing — but a marker also forces `content` from a
    # string into an array, and there is no reason to reshape a payload that
    # nothing will read.
    private def cache_route?(model : String) : Bool
      @cache && model.starts_with?(ANTHROPIC_PREFIX)
    end

    private def build_payload(model : String, request : Request, streaming : Bool = false) : String
      caching = cache_route?(model)
      # Only computed to be compared against, so an off route never enters the
      # branch at all and the payload stays byte-identical to before caching.
      breakpoint = caching ? transcript_breakpoint(request.messages) : nil

      String.build do |str|
        JSON.build(str) do |json|
          json.object do
            json.field "model", model

            if streaming
              json.field "stream", true
              json.field "stream_options" do
                json.object { json.field "include_usage", true }
              end
            end

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
                    if caching
                      # The one breakpoint that reliably pays. Anthropic caches
                      # the prefix in the order tools → system → messages, so a
                      # marker here covers the tool definitions as well — which
                      # is just as well, because a marker *on* a tool
                      # definition is dropped by OpenRouter without a word.
                      json.field "content" do
                        json.array do
                          text_part(json, sys, cache: true)
                        end
                      end
                    else
                      json.field "content", sys
                    end
                  end
                end

                # Messages translation
                request.messages.each_with_index do |msg, index|
                  serialize_message(json, msg, cache: index == breakpoint)
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

    private def serialize_message(json : JSON::Builder, msg : Message, cache : Bool = false)
      case msg.role
      when Role::User
        text_content = msg.content.select { |b| b.type.text? }.map(&.text).compact.join("\n")
        images = OpenAIContent.images(msg)

        json.object do
          json.field "role", "user"
          if cache || !images.empty?
            json.field "content" do
              json.array do
                # The marker rides on the text part. A turn that is nothing
                # but an image gets none: a marker belongs on the last block
                # of the prefix being cached, and putting it on an image part
                # is a shape this route has not been tried with — the same
                # reason tool results are left unmarked below.
                text_part(json, text_content, cache: cache) unless text_content.empty? && !images.empty?
                images.each { |image| OpenAIContent.image_part(json, image) }
              end
            end
          else
            json.field "content", text_content
          end
        end
      when Role::Assistant
        tool_uses = msg.content.select { |b| b.type.tool_use? }
        text_content = msg.content.select { |b| b.type.text? }.map(&.text).compact.join("\n")

        json.object do
          json.field "role", "assistant"
          # `content: null` is the OpenAI convention for a tool-call-only
          # message, but a null with *no* tool_calls is rejected — Ollama
          # answers 400 "invalid message content type: <nil>" — and since the
          # whole transcript is resent every turn, one such message breaks the
          # rest of the session.
          json.field "content", text_content.empty? && !tool_uses.empty? ? nil : text_content

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
        # No marker here even when the breakpoint lands on a tool turn. A
        # `role: "tool"` message with an array `content` is not a shape this
        # route has been tried with, and getting it wrong fails every request
        # of the session, not one. What is given up is small: the rolling
        # breakpoint only pays on a large turn, and the triage measured a
        # marker on a short block as discarded anyway.
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

    # An OpenAI content part. Only reached on a caching route — everywhere
    # else `content` stays the plain string it has always been.
    private def text_part(json : JSON::Builder, text : String, cache : Bool) : Nil
      json.object do
        json.field "type", "text"
        json.field "text", text
        cache_control(json) if cache
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
        usage = if cache_route?(model)
                  AnthropicCaching.usage(u)
                else
                  Usage.new(
                    u["prompt_tokens"]?.try(&.as_i) || 0,
                    u["completion_tokens"]?.try(&.as_i) || 0,
                    u["total_tokens"]?.try(&.as_i) || 0
                  )
                end
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
