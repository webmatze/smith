require "../../spec_helper"
require "../../../src/smith/llm/anthropic"
require "../../../src/smith/llm/openai"
require "../../../src/smith/llm/openrouter"
require "../../../src/smith/llm/ollama"

# Crystal's `private` is callable from a subclass without an explicit receiver,
# so this reaches the real builder rather than a copy of it.
private class ProbeAnthropic < Smith::LLM::Anthropic
  def payload_for(request : Smith::LLM::Request) : JSON::Any
    JSON.parse(build_payload("claude-sonnet-5", request))
  end
end

private def probe(cache : Bool = true)
  ProbeAnthropic.new(api_key: "k", cache: cache)
end

private def tool(name : String)
  Smith::LLM::ToolSpec.new(name, "does #{name}", JSON.parse(%({"type": "object"})))
end

private def request(
  messages : Array(Smith::LLM::Message) = [Smith::LLM::Message.user("hi")],
  system : String? = "You are Smith.",
  tools : Array(Smith::LLM::ToolSpec)? = [tool("read_file"), tool("write_file")],
)
  Smith::LLM::Request.new(model: "claude-sonnet-5", messages: messages, system: system, tools: tools)
end

# Every cache_control marker anywhere in the payload.
private def markers(payload : JSON::Any) : Array(String)
  found = [] of String

  walk = uninitialized JSON::Any, String -> Nil
  walk = ->(node : JSON::Any, path : String) do
    if hash = node.as_h?
      found << path if hash.has_key?("cache_control")
      hash.each { |key, value| walk.call(value, path.empty? ? key : "#{path}.#{key}") }
    elsif array = node.as_a?
      array.each_with_index { |value, index| walk.call(value, "#{path}[#{index}]") }
    end
  end
  walk.call(payload, "")

  found
end

describe "Anthropic prompt caching" do
  it "sends the system prompt in block form with a cache breakpoint" do
    system = probe.payload_for(request)["system"]

    system.as_a.size.should eq(1)
    system[0]["type"].as_s.should eq("text")
    system[0]["text"].as_s.should eq("You are Smith.")
    system[0]["cache_control"]["type"].as_s.should eq("ephemeral")
  end

  it "marks only the last tool, which caches the whole block before it" do
    tools = probe.payload_for(request)["tools"].as_a

    tools.size.should eq(2)
    tools[0]["cache_control"]?.should be_nil
    tools[1]["cache_control"]["type"].as_s.should eq("ephemeral")
  end

  it "leaves the tool order alone, since reordering would miss the cache" do
    names = probe.payload_for(request(tools: [tool("bash"), tool("read_file"), tool("glob")]))["tools"]
      .as_a.map(&.["name"].as_s)

    names.should eq(["bash", "read_file", "glob"])
  end

  it "rolls a breakpoint along the transcript, on the second-to-last user turn" do
    messages = [
      Smith::LLM::Message.user("first"),
      Smith::LLM::Message.assistant("ok"),
      Smith::LLM::Message.user("second"),
      Smith::LLM::Message.assistant("ok"),
      Smith::LLM::Message.user("third"),
    ]

    payload = probe.payload_for(request(messages: messages))
    serialized = payload["messages"].as_a

    # The newest user turn changes next request, so marking it would write a
    # cache nothing ever reads. The one before it stays put.
    serialized[2]["content"][0]["cache_control"]["type"].as_s.should eq("ephemeral")
    serialized[0]["content"][0]["cache_control"]?.should be_nil
    serialized[4]["content"][0]["cache_control"]?.should be_nil
  end

  it "treats tool results as the user turns they are sent as" do
    messages = [
      Smith::LLM::Message.user("do it"),
      Smith::LLM::Message.assistant("ok"),
      Smith::LLM::Message.tool_results([Smith::LLM::ContentBlock.tool_result("call_1", "done")]),
      Smith::LLM::Message.assistant("ok"),
      Smith::LLM::Message.user("thanks"),
    ]

    serialized = probe.payload_for(request(messages: messages))["messages"].as_a
    serialized[2]["content"][0]["cache_control"]["type"].as_s.should eq("ephemeral")
  end

  it "skips the transcript breakpoint when there is nothing stable to cache yet" do
    payload = probe.payload_for(request(messages: [Smith::LLM::Message.user("hi")]))

    payload["messages"].as_a[0]["content"][0]["cache_control"]?.should be_nil
  end

  it "stays within Anthropic's four breakpoints" do
    messages = (1..10).flat_map do |i|
      [Smith::LLM::Message.user("q#{i}"), Smith::LLM::Message.assistant("a#{i}")]
    end

    markers(probe.payload_for(request(messages: messages))).size.should be <= 4
  end

  it "emits no cache_control at all when caching is off" do
    payload = probe(cache: false).payload_for(request(messages: [
      Smith::LLM::Message.user("a"),
      Smith::LLM::Message.assistant("b"),
      Smith::LLM::Message.user("c"),
    ]))

    markers(payload).should be_empty
    # And the system prompt goes back to the plain string form.
    payload["system"].as_s.should eq("You are Smith.")
  end

  it "omits the system field entirely when there is none" do
    probe.payload_for(request(system: nil))["system"]?.should be_nil
  end
end

describe Smith::LLM::Usage do
  it "defaults the cache counters to zero, so other providers are unaffected" do
    usage = Smith::LLM::Usage.new(10, 5, 15)

    usage.cache_creation_tokens.should eq(0)
    usage.cache_read_tokens.should eq(0)
    usage.cached_tokens.should eq(0)
  end

  it "adds every field, cache counters included" do
    a = Smith::LLM::Usage.new(10, 5, 15, cache_creation_tokens: 100, cache_read_tokens: 200)
    b = Smith::LLM::Usage.new(1, 2, 3, cache_creation_tokens: 10, cache_read_tokens: 20)

    sum = a + b
    sum.prompt_tokens.should eq(11)
    sum.completion_tokens.should eq(7)
    sum.total_tokens.should eq(18)
    sum.cache_creation_tokens.should eq(110)
    sum.cache_read_tokens.should eq(220)
    sum.cached_tokens.should eq(330)
  end
end

private class ParseProbe < Smith::LLM::Anthropic
  def parse(body : String) : Smith::LLM::Response
    parse_response(body)
  end
end

describe "cache usage parsing" do
  it "reads the cache counters from a non-streaming response" do
    usage = ParseProbe.new(api_key: "k").parse(%({
      "id": "msg_1",
      "model": "claude-sonnet-5",
      "content": [{"type": "text", "text": "hi"}],
      "usage": {
        "input_tokens": 12,
        "output_tokens": 34,
        "cache_creation_input_tokens": 1200,
        "cache_read_input_tokens": 5900
      }
    })).usage.not_nil!

    usage.prompt_tokens.should eq(12)
    usage.completion_tokens.should eq(34)
    usage.cache_creation_tokens.should eq(1200)
    usage.cache_read_tokens.should eq(5900)
  end

  it "defaults them to zero when the response omits them" do
    usage = ParseProbe.new(api_key: "k").parse(%({
      "id": "msg_1", "model": "m", "content": [],
      "usage": {"input_tokens": 12, "output_tokens": 34}
    })).usage.not_nil!

    usage.cached_tokens.should eq(0)
  end

  it "reads them on the streaming path too, which is the default" do
    sse = <<-SSE
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","model":"claude-sonnet-5","usage":{"input_tokens":12,"cache_creation_input_tokens":1200,"cache_read_input_tokens":5900}}}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":34}}

    data: [DONE]

    SSE

    response = Smith::LLM::AnthropicStream.read(IO::Memory.new(sse), "claude-sonnet-5") { |_| }

    usage = response.usage.not_nil!
    usage.prompt_tokens.should eq(12)
    usage.completion_tokens.should eq(34)
    usage.cache_creation_tokens.should eq(1200)
    usage.cache_read_tokens.should eq(5900)
  end
end

private class ProbeOpenRouter < Smith::LLM::OpenRouter
  def raw_payload_for(request : Smith::LLM::Request, model : String) : String
    build_payload(model, request)
  end

  def payload_for(request : Smith::LLM::Request, model : String) : JSON::Any
    JSON.parse(raw_payload_for(request, model))
  end

  def parse(body : String) : Smith::LLM::Response
    parse_response(body)
  end
end

private def openrouter(cache : Bool = true)
  ProbeOpenRouter.new(api_key: "k", cache: cache)
end

private def or_request(
  messages : Array(Smith::LLM::Message) = [Smith::LLM::Message.user("hi")],
  system : String? = "You are Smith.",
  tools : Array(Smith::LLM::ToolSpec)? = [tool("read_file"), tool("write_file")],
)
  Smith::LLM::Request.new(model: "", messages: messages, system: system, tools: tools)
end

# Three turns, so there is a second-to-last user turn to roll onto.
private def or_turns
  [
    Smith::LLM::Message.user("first"),
    Smith::LLM::Message.assistant("ok"),
    Smith::LLM::Message.user("second"),
    Smith::LLM::Message.assistant("ok"),
    Smith::LLM::Message.user("third"),
  ]
end

describe "OpenRouter prompt caching" do
  it "marks the system prompt in multipart form on an anthropic route" do
    system = openrouter.payload_for(or_request, "anthropic/claude-sonnet-5")["messages"][0]

    system["role"].as_s.should eq("system")
    system["content"].as_a.size.should eq(1)
    system["content"][0]["type"].as_s.should eq("text")
    system["content"][0]["text"].as_s.should eq("You are Smith.")
    system["content"][0]["cache_control"]["type"].as_s.should eq("ephemeral")
  end

  it "leaves the tool definitions unmarked, since OpenRouter discards those" do
    payload = openrouter.payload_for(or_request, "anthropic/claude-sonnet-5")

    payload["tools"].as_a.each { |t| markers(t).should be_empty }
  end

  it "rolls a breakpoint along the transcript, on the second-to-last user turn" do
    messages = openrouter.payload_for(or_request(messages: or_turns), "anthropic/claude-sonnet-5")["messages"].as_a

    # Index 0 is the system prompt, so the transcript starts at 1.
    messages[3]["content"][0]["cache_control"]["type"].as_s.should eq("ephemeral")
    messages[1]["content"].as_s.should eq("first")
    messages[5]["content"].as_s.should eq("third")
  end

  it "stays well inside Anthropic's four breakpoints" do
    messages = (1..10).flat_map do |i|
      [Smith::LLM::Message.user("q#{i}"), Smith::LLM::Message.assistant("a#{i}")]
    end

    markers(openrouter.payload_for(or_request(messages: messages), "anthropic/claude-opus-5")).size.should eq(2)
  end

  it "skips the marker when the breakpoint lands on a tool result" do
    messages = [
      Smith::LLM::Message.user("do it"),
      Smith::LLM::Message.assistant("ok"),
      Smith::LLM::Message.tool_results([Smith::LLM::ContentBlock.tool_result("call_1", "done")]),
      Smith::LLM::Message.assistant("ok"),
      Smith::LLM::Message.user("thanks"),
    ]

    payload = openrouter.payload_for(or_request(messages: messages), "anthropic/claude-sonnet-5")

    # Only the system prompt is marked; the tool turn keeps its string content.
    markers(payload).should eq(["messages[0].content[0]"])
    payload["messages"][3]["content"].as_s.should eq("done")
  end

  it "sends a non-anthropic route the payload it has always sent, cache flag or not" do
    request = or_request(messages: or_turns)

    with_cache = openrouter(cache: true).raw_payload_for(request, "openai/gpt-5.6")
    without = openrouter(cache: false).raw_payload_for(request, "openai/gpt-5.6")

    with_cache.should eq(without)
    markers(JSON.parse(with_cache)).should be_empty
  end

  it "sends an anthropic route the same payload when caching is off" do
    request = or_request(messages: or_turns)

    off = openrouter(cache: false).raw_payload_for(request, "anthropic/claude-sonnet-5")

    # Byte-identical to the shape every other model gets: flat string content.
    off.should eq(openrouter(cache: false).raw_payload_for(request, "openai/gpt-5.6").sub("openai/gpt-5.6", "anthropic/claude-sonnet-5"))
    markers(JSON.parse(off)).should be_empty
  end
end

describe "OpenRouter cache usage parsing" do
  # OpenRouter counts the cached tokens *inside* prompt_tokens; smith's
  # prompt_tokens is the uncached remainder and the cost model adds the cache
  # counters on top. Passing the number through would bill the prefix twice.
  it "subtracts the cached tokens out of the prompt count" do
    usage = openrouter.parse(%({
      "id": "gen_1",
      "model": "anthropic/claude-haiku-4.5",
      "choices": [{"message": {"content": "hi"}, "finish_reason": "stop"}],
      "usage": {
        "prompt_tokens": 4199,
        "completion_tokens": 34,
        "total_tokens": 4233,
        "prompt_tokens_details": {"cached_tokens": 4187}
      }
    })).usage.not_nil!

    usage.prompt_tokens.should eq(12)
    usage.cache_read_tokens.should eq(4187)
    usage.completion_tokens.should eq(34)
    usage.billed_prompt_tokens.should eq(4199)
  end

  it "reads a cache write the same way" do
    usage = openrouter.parse(%({
      "id": "gen_1",
      "model": "anthropic/claude-haiku-4.5",
      "choices": [{"message": {"content": "hi"}, "finish_reason": "stop"}],
      "usage": {
        "prompt_tokens": 4199,
        "completion_tokens": 34,
        "prompt_tokens_details": {"cache_write_tokens": 4187, "cached_tokens": 0}
      }
    })).usage.not_nil!

    usage.prompt_tokens.should eq(12)
    usage.cache_creation_tokens.should eq(4187)
    usage.cache_read_tokens.should eq(0)
  end

  it "leaves both counters at zero when the details are missing" do
    usage = openrouter.parse(%({
      "id": "gen_1",
      "model": "anthropic/claude-haiku-4.5",
      "choices": [{"message": {"content": "hi"}, "finish_reason": "stop"}],
      "usage": {"prompt_tokens": 4199, "completion_tokens": 34, "total_tokens": 4233}
    })).usage.not_nil!

    usage.prompt_tokens.should eq(4199)
    usage.cached_tokens.should eq(0)
  end

  it "does not touch a non-anthropic route, whose cached_tokens are billed differently" do
    usage = openrouter.parse(%({
      "id": "gen_1",
      "model": "openai/gpt-5.6",
      "choices": [{"message": {"content": "hi"}, "finish_reason": "stop"}],
      "usage": {
        "prompt_tokens": 4199,
        "completion_tokens": 34,
        "total_tokens": 4233,
        "prompt_tokens_details": {"cached_tokens": 4187}
      }
    })).usage.not_nil!

    usage.prompt_tokens.should eq(4199)
    usage.cached_tokens.should eq(0)
  end

  it "reads them on the streaming path too, which is the default" do
    sse = <<-SSE
    data: {"id":"gen_1","model":"anthropic/claude-haiku-4.5","choices":[{"delta":{"content":"hi"},"finish_reason":"stop"}]}

    data: {"id":"gen_1","model":"anthropic/claude-haiku-4.5","choices":[],"usage":{"prompt_tokens":4199,"completion_tokens":34,"total_tokens":4233,"prompt_tokens_details":{"cached_tokens":4187}}}

    data: [DONE]

    SSE

    usage = Smith::LLM::OpenAIStream
      .read(IO::Memory.new(sse), "anthropic/claude-haiku-4.5", cache_usage: true) { |_| }
      .usage.not_nil!

    usage.prompt_tokens.should eq(12)
    usage.cache_read_tokens.should eq(4187)
  end

  it "leaves the stream reading alone for everyone else" do
    sse = <<-SSE
    data: {"id":"c_1","model":"gpt-5.6","choices":[{"delta":{"content":"hi"}}]}

    data: {"id":"c_1","model":"gpt-5.6","choices":[],"usage":{"prompt_tokens":4199,"completion_tokens":34,"total_tokens":4233,"prompt_tokens_details":{"cached_tokens":4187}}}

    data: [DONE]

    SSE

    usage = Smith::LLM::OpenAIStream.read(IO::Memory.new(sse), "gpt-5.6") { |_| }.usage.not_nil!

    usage.prompt_tokens.should eq(4199)
    usage.cached_tokens.should eq(0)
  end
end
