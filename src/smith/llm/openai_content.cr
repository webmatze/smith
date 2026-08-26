require "json"
require "./types"

module Smith::LLM
  # The OpenAI content shape, shared by the three adapters that speak it.
  #
  # `content` is a plain string until a message carries something that is not
  # text; then it has to become an array of parts. Keeping that switch in one
  # place is what stops the three from drifting — the string form is the one
  # every existing session was written with, and a provider that reshaped it
  # for no reason would invalidate its own prompt cache.
  module OpenAIContent
    # An image as a data URI. There is no document part in this shape: a PDF
    # never reaches here, because the agent has already replaced it with text
    # for any provider whose `supports_documents?` says no.
    def self.image_part(json : JSON::Builder, block : ContentBlock) : Nil
      json.object do
        json.field "type", "image_url"
        json.field "image_url" do
          json.object do
            json.field "url", "data:#{block.media_type};base64,#{block.data}"
          end
        end
      end
    end

    # The attachments of a message, in the order they were written.
    def self.images(msg : Message) : Array(ContentBlock)
      msg.content.select { |b| b.type.image? && b.data }
    end
  end
end
