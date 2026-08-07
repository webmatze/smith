require "json"
require "./types"
require "./sse"

module Smith::LLM
  # Reads Anthropic's Messages streaming format, which is shaped quite
  # differently from OpenAI's: named events carrying indexed content blocks
  # rather than a single delta object.
  #
  #   message_start        -> input tokens
  #   content_block_start  -> block type (text | tool_use), id and name
  #   content_block_delta  -> text_delta, or input_json_delta for tool args
  #   content_block_stop
  #   message_delta        -> stop_reason, output tokens
  module AnthropicStream
    private struct PartialBlock
      property type : String = "text"
      property text : String = ""
      property id : String = ""
      property name : String = ""
      property partial_json : String = ""
    end

    def self.read(io : IO, default_model : String, &on_delta : String -> Nil) : Response
      blocks = Hash(Int32, PartialBlock).new
      id = ""
      model = default_model
      stop_reason : String? = nil
      input_tokens = 0
      output_tokens = 0

      SSE.each_data(io) do |payload|
        event = begin
          JSON.parse(payload)
        rescue JSON::ParseException
          next
        end

        case event["type"]?.try(&.as_s?)
        when "message_start"
          if message = event["message"]?
            id = message["id"]?.try(&.as_s?) || id
            model = message["model"]?.try(&.as_s?) || model
            input_tokens = message["usage"]?.try(&.["input_tokens"]?).try(&.as_i?) || input_tokens
          end
        when "content_block_start"
          index = event["index"]?.try(&.as_i?) || 0
          partial = PartialBlock.new

          if block = event["content_block"]?
            partial.type = block["type"]?.try(&.as_s?) || "text"
            partial.id = block["id"]?.try(&.as_s?) || ""
            partial.name = block["name"]?.try(&.as_s?) || ""
            partial.text = block["text"]?.try(&.as_s?) || ""
          end

          blocks[index] = partial
        when "content_block_delta"
          index = event["index"]?.try(&.as_i?) || 0
          partial = blocks[index] ||= PartialBlock.new
          delta = event["delta"]?
          next unless delta

          case delta["type"]?.try(&.as_s?)
          when "text_delta"
            if chunk = delta["text"]?.try(&.as_s?)
              partial.text += chunk
              on_delta.call(chunk)
            end
          when "input_json_delta"
            # Tool arguments arrive as fragments and only form valid JSON once
            # the block stops, so they are stitched together first.
            if chunk = delta["partial_json"]?.try(&.as_s?)
              partial.partial_json += chunk
            end
          end

          blocks[index] = partial
        when "message_delta"
          if delta = event["delta"]?
            stop_reason = delta["stop_reason"]?.try(&.as_s?) || stop_reason
          end
          output_tokens = event["usage"]?.try(&.["output_tokens"]?).try(&.as_i?) || output_tokens
        end
      end

      usage = if input_tokens > 0 || output_tokens > 0
                Usage.new(input_tokens, output_tokens, input_tokens + output_tokens)
              end

      Response.new(
        id: id.empty? ? "anthropic-stream-#{Time.local.to_unix}" : id,
        model: model,
        content: build_blocks(blocks),
        stop_reason: stop_reason,
        usage: usage
      )
    end

    private def self.build_blocks(blocks : Hash(Int32, PartialBlock)) : Array(ContentBlock)
      result = Array(ContentBlock).new

      blocks.keys.sort.each do |index|
        partial = blocks[index]

        case partial.type
        when "text"
          result << ContentBlock.text(partial.text) unless partial.text.empty?
        when "tool_use"
          next if partial.name.empty?

          args = begin
            JSON.parse(partial.partial_json.presence || "{}")
          rescue JSON::ParseException
            JSON.parse("{}")
          end

          result << ContentBlock.tool_use(partial.id.presence || "call_#{index}", partial.name, args)
        end
      end

      result
    end
  end
end
