require "../../spec_helper"
require "../../../src/smith/llm/anthropic"
require "../../../src/smith/llm/openai"
require "../../../src/smith/llm/openrouter"
require "../../../src/smith/llm/ollama"

# `private` in Crystal is callable from a subclass without an explicit
# receiver, so each probe reaches the real payload builder rather than a copy
# of it — the same trick prompt_caching_spec uses.
private class ProbeAnthropic < Smith::LLM::Anthropic
  def payload_for(request : Smith::LLM::Request) : JSON::Any
    JSON.parse(build_payload("claude-sonnet-5", request))
  end
end

private class ProbeOpenAI < Smith::LLM::OpenAI
  def payload_for(request : Smith::LLM::Request) : JSON::Any
    JSON.parse(build_payload("gpt-5.6-luna", request))
  end
end

private class ProbeOpenRouter < Smith::LLM::OpenRouter
  # The model id is what decides whether caching applies at all on this route,
  # so it comes from the request rather than being pinned here.
  def payload_for(request : Smith::LLM::Request) : JSON::Any
    JSON.parse(build_payload(request.model, request))
  end
end

private class ProbeOllama < Smith::LLM::Ollama
  def payload_for(request : Smith::LLM::Request) : JSON::Any
    JSON.parse(build_payload("gemma4:latest", request))
  end
end

private def image_message(text : String = "what is wrong here?")
  Smith::LLM::Message.new(Smith::LLM::Role::User, [
    Smith::LLM::ContentBlock.text(text),
    Smith::LLM::ContentBlock.image("image/png", "QUJD", "shot.png"),
  ])
end

private def request(message : Smith::LLM::Message)
  Smith::LLM::Request.new(model: "m", messages: [message], system: "You are Smith.", tools: nil)
end

# The OpenAI shape carries the system prompt as the first message; Anthropic
# carries it in a field of its own. Finding the user turn by role rather than
# by index keeps one set of assertions working against both.
private def user_content(payload : JSON::Any) : JSON::Any
  payload["messages"].as_a.find! { |message| message["role"] == "user" }["content"]
end

describe "image and document serialization" do
  describe Smith::LLM::Anthropic do
    it "sends an image as a base64 source block, after the text it belongs to" do
      payload = ProbeAnthropic.new(api_key: "k", cache: false).payload_for(request(image_message))
      content = user_content(payload).as_a

      content.size.should eq(2)
      content[0]["type"].should eq("text")
      content[1]["type"].should eq("image")
      content[1]["source"]["type"].should eq("base64")
      content[1]["source"]["media_type"].should eq("image/png")
      content[1]["source"]["data"].should eq("QUJD")
    end

    it "sends a PDF as a document block, which is the shape only it takes" do
      message = Smith::LLM::Message.new(Smith::LLM::Role::User, [
        Smith::LLM::ContentBlock.text("summarise this"),
        Smith::LLM::ContentBlock.document("application/pdf", "JVBERi0=", "paper.pdf"),
      ])

      content = user_content(ProbeAnthropic.new(api_key: "k", cache: false).payload_for(request(message))).as_a

      content[1]["type"].should eq("document")
      content[1]["source"]["media_type"].should eq("application/pdf")
    end

    it "keeps a text-only turn exactly as it was" do
      message = Smith::LLM::Message.user("no attachments here")
      content = user_content(ProbeAnthropic.new(api_key: "k", cache: false).payload_for(request(message))).as_a

      content.size.should eq(1)
      content[0]["type"].should eq("text")
    end

    it "reports documents as supported and every other provider does not" do
      Smith::LLM::Anthropic.new(api_key: "k").supports_documents?.should be_true
      Smith::LLM::OpenAI.new(api_key: "k").supports_documents?.should be_false
      Smith::LLM::OpenRouter.new(api_key: "k").supports_documents?.should be_false
      Smith::LLM::Ollama.new.supports_documents?.should be_false
    end
  end

  describe "the OpenAI content shape" do
    it "switches content to parts with a data URI, for each of the three" do
      payloads = {
        "openai"     => ProbeOpenAI.new(api_key: "k").payload_for(request(image_message)),
        "openrouter" => ProbeOpenRouter.new(api_key: "k").payload_for(request(image_message)),
        "ollama"     => ProbeOllama.new.payload_for(request(image_message)),
      }

      payloads.each do |name, payload|
        content = user_content(payload).as_a
        content.size.should eq(2), "#{name} should send two parts"
        content[0]["type"].should eq("text")
        content[1]["type"].should eq("image_url")
        content[1]["image_url"]["url"].should eq("data:image/png;base64,QUJD")
      end
    end

    it "keeps the OpenRouter cache marker on the text part beside an image" do
      # The breakpoint is the second-to-last user turn, so it takes two of
      # them before there is anything to mark — and the image turn is the one
      # that gets it.
      payload = ProbeOpenRouter.new(api_key: "k", cache: true)
        .payload_for(Smith::LLM::Request.new(
          model: "anthropic/claude-sonnet-5",
          messages: [
            image_message,
            Smith::LLM::Message.assistant("a button is misaligned"),
            Smith::LLM::Message.user("and now?"),
          ],
          system: "You are Smith.",
          tools: nil
        ))

      # The system prompt is an array on this route too, so the turn is picked
      # by the part that only the image message has.
      content = payload["messages"].as_a.compact_map(&.["content"].as_a?)
        .find! { |parts| parts.any? { |part| part["type"] == "image_url" } }
      content[0]["type"].should eq("text")
      content[0]["cache_control"]["type"].should eq("ephemeral")
      # Never on the image part: that shape has not been tried on this route,
      # and being wrong there fails every request of the session.
      content[1].as_h.has_key?("cache_control").should be_false
    end

    it "leaves a text-only turn as a plain string, so no existing prefix is reshaped" do
      message = Smith::LLM::Message.user("still just text")

      user_content(ProbeOpenAI.new(api_key: "k").payload_for(request(message))).should eq("still just text")
      user_content(ProbeOllama.new.payload_for(request(message))).should eq("still just text")
    end
  end
end

# A tool turn as the registry now builds it: the result, and the image the
# call produced beside it under the same id.
private def tool_message_with_image(id : String = "t1")
  Smith::LLM::Message.new(Smith::LLM::Role::Tool, [
    Smith::LLM::ContentBlock.tool_result(id, "Attached 'shot.png' as image/png (12 B)."),
    Smith::LLM::ContentBlock.new(
      Smith::LLM::ContentBlock::BlockType::Image,
      tool_call_id: id,
      media_type: "image/png",
      data: "QUJD",
      source: "shot.png"
    ),
  ])
end

private def tool_content(payload : JSON::Any, index : Int32 = 0) : JSON::Any
  payload["messages"].as_a.last["content"].as_a[index]
end

describe "an attachment returned by a tool" do
  describe Smith::LLM::Anthropic do
    it "folds it into the content of the result it belongs to" do
      payload = ProbeAnthropic.new(api_key: "k", cache: false)
        .payload_for(request(tool_message_with_image))

      result = tool_content(payload)
      result["type"].should eq("tool_result")
      result["tool_use_id"].should eq("t1")

      parts = result["content"].as_a
      parts.size.should eq(2)
      parts[0]["type"].should eq("text")
      parts[0]["text"].as_s.should contain("shot.png")
      parts[1]["type"].should eq("image")
      parts[1]["source"]["type"].should eq("base64")
      parts[1]["source"]["media_type"].should eq("image/png")
      parts[1]["source"]["data"].should eq("QUJD")
    end

    it "leaves a text-only result a plain string, so no running prefix is reshaped" do
      message = Smith::LLM::Message.new(Smith::LLM::Role::Tool, [
        Smith::LLM::ContentBlock.tool_result("t1", "1: alpha"),
      ])

      tool_content(ProbeAnthropic.new(api_key: "k", cache: false).payload_for(request(message)))["content"]
        .should eq("1: alpha")
    end

    it "says so, so the agent knows it need not downgrade" do
      Smith::LLM::Anthropic.new(api_key: "k").supports_tool_result_media?.should be_true
    end
  end

  describe "the OpenAI shape" do
    it "has nowhere to put one, and says so" do
      Smith::LLM::OpenAI.new(api_key: "k").supports_tool_result_media?.should be_false
      Smith::LLM::OpenRouter.new(api_key: "k").supports_tool_result_media?.should be_false
      Smith::LLM::Ollama.new.supports_tool_result_media?.should be_false
    end

    it "never smuggles an image into a tool message" do
      [
        ProbeOpenAI.new(api_key: "k").payload_for(request(tool_message_with_image)),
        ProbeOllama.new.payload_for(request(tool_message_with_image)),
        ProbeOpenRouter.new(api_key: "k", cache: false).payload_for(request(tool_message_with_image)),
      ].each do |payload|
        tool_turns = payload["messages"].as_a.select { |message| message["role"] == "tool" }
        tool_turns.size.should eq(1)
        tool_turns.first["content"].as_s.should contain("shot.png")
        payload.to_json.should_not contain("image_url")
      end
    end
  end
end
