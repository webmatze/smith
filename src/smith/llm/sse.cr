require "json"
require "./types"

module Smith::LLM
  # Server-Sent Events framing: blank-line separated records whose payload
  # lives on `data:` lines.
  module SSE
    DONE = "[DONE]"

    # Yields the payload of every `data:` line, stopping at the [DONE]
    # sentinel or end of stream.
    def self.each_data(io : IO, &)
      while line = io.gets
        line = line.strip
        next if line.empty?
        next unless line.starts_with?("data:")

        payload = line[5..].strip
        break if payload == DONE
        next if payload.empty?

        yield payload
      end
    end
  end

  # Reads an OpenAI-shaped chat completion stream.
  #
  # Shared by OpenRouter, OpenAI *and* Ollama — smith talks to Ollama through
  # its OpenAI-compatible /v1/chat/completions endpoint, so all three speak
  # this format.
  module OpenAIStream
    # Tool calls arrive spread across chunks: `function.arguments` is delivered
    # as string fragments that only form valid JSON once the last one has
    # landed. So arguments are accumulated per index and parsed at the end.
    private struct PartialToolCall
      property id : String = ""
      property name : String = ""
      property arguments : String = ""
    end

    def self.read(io : IO, default_model : String, &on_delta : String -> Nil) : Response
      text = String::Builder.new
      tool_calls = Hash(Int32, PartialToolCall).new
      id = ""
      model = default_model
      finish_reason : String? = nil
      usage : Usage? = nil

      SSE.each_data(io) do |payload|
        chunk = begin
          JSON.parse(payload)
        rescue JSON::ParseException
          # A malformed frame must not kill an otherwise healthy stream.
          next
        end

        id = chunk["id"]?.try(&.as_s?) || id
        model = chunk["model"]?.try(&.as_s?) || model

        if u = chunk["usage"]?
          unless u.raw.nil?
            prompt = u["prompt_tokens"]?.try(&.as_i?) || 0
            completion = u["completion_tokens"]?.try(&.as_i?) || 0
            total = u["total_tokens"]?.try(&.as_i?) || (prompt + completion)
            usage = Usage.new(prompt, completion, total)
          end
        end

        choice = chunk["choices"]?.try(&.as_a?).try(&.first?)
        next unless choice

        finish_reason = choice["finish_reason"]?.try(&.as_s?) || finish_reason

        delta = choice["delta"]?
        next unless delta

        if content = delta["content"]?.try(&.as_s?)
          unless content.empty?
            text << content
            on_delta.call(content)
          end
        end

        if calls = delta["tool_calls"]?.try(&.as_a?)
          calls.each do |call|
            index = call["index"]?.try(&.as_i?) || 0
            partial = tool_calls[index] ||= PartialToolCall.new

            partial.id = call["id"].as_s if call["id"]?.try(&.as_s?)

            if function = call["function"]?
              partial.name = function["name"].as_s if function["name"]?.try(&.as_s?)
              if args = function["arguments"]?.try(&.as_s?)
                partial.arguments += args
              end
            end

            tool_calls[index] = partial
          end
        end
      end

      Response.new(
        id: id.empty? ? "stream-#{Time.local.to_unix}" : id,
        model: model,
        content: build_blocks(text.to_s, tool_calls),
        stop_reason: finish_reason,
        usage: usage
      )
    end

    private def self.build_blocks(text : String, tool_calls : Hash(Int32, PartialToolCall)) : Array(ContentBlock)
      blocks = Array(ContentBlock).new
      blocks << ContentBlock.text(text) unless text.empty?

      tool_calls.keys.sort.each do |index|
        partial = tool_calls[index]
        next if partial.name.empty?

        args = begin
          JSON.parse(partial.arguments.presence || "{}")
        rescue JSON::ParseException
          JSON.parse("{}")
        end

        call_id = partial.id.presence || "call_#{index}"
        blocks << ContentBlock.tool_use(call_id, partial.name, args)
      end

      blocks
    end
  end
end
