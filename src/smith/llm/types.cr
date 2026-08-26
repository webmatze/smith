require "json"

module Smith::LLM
  enum Role
    System
    User
    Assistant
    Tool

    def to_s
      super.downcase
    end

    def self.from_string(role : String) : Role
      case role.downcase
      when "system"    then System
      when "user"      then User
      when "assistant" then Assistant
      when "tool"      then Tool
      else
        raise ArgumentError.new("Unknown role: #{role}")
      end
    end
  end

  # Content block can represent text, tool calls, or tool results
  class ContentBlock
    include JSON::Serializable

    enum BlockType
      Text
      ToolUse
      ToolResult
      Thinking
      RedactedThinking
      Image
      Document
    end

    getter type : BlockType
    getter text : String?
    getter tool_call_id : String?
    getter tool_name : String?
    getter tool_args : JSON::Any?
    getter is_error : Bool?

    # Anthropic's cryptographic signature over a thinking block. It must go
    # back exactly as it came: never truncated, normalised or regenerated, or
    # the next request is rejected. Defaulted in the declaration so sessions
    # saved before thinking existed still deserialize.
    getter signature : String? = nil

    # An attached image or PDF. `media_type` is what the bytes actually are,
    # never what the file was called, and `source` is the name only so a
    # renderer has something to print.
    getter media_type : String? = nil
    getter source : String? = nil

    # The base64 payload, and the one field that must never be written
    # anywhere. It is resent in full on every turn of the session, so a copy
    # in session.json and a second copy in the raw transcript log would grow
    # with each resume and be read by nobody. The session store puts the bytes
    # in a file of their own and leaves `media_ref` behind to find them again;
    # everything else that serializes a message gets the metadata and no blob.
    @[JSON::Field(ignore: true)]
    property data : String? = nil

    property media_ref : String? = nil

    def initialize(@type : BlockType, @text : String? = nil, @tool_call_id : String? = nil, @tool_name : String? = nil, @tool_args : JSON::Any? = nil, @is_error : Bool? = nil, @signature : String? = nil, @media_type : String? = nil, @data : String? = nil, @source : String? = nil, @media_ref : String? = nil)
    end

    def self.text(content : String) : ContentBlock
      ContentBlock.new(BlockType::Text, text: content)
    end

    def self.tool_use(id : String, name : String, args : JSON::Any) : ContentBlock
      ContentBlock.new(BlockType::ToolUse, tool_call_id: id, tool_name: name, tool_args: args)
    end

    def self.tool_result(id : String, result : String, is_error : Bool = false) : ContentBlock
      ContentBlock.new(BlockType::ToolResult, text: result, tool_call_id: id, is_error: is_error)
    end

    def self.thinking(content : String, signature : String? = nil) : ContentBlock
      ContentBlock.new(BlockType::Thinking, text: content, signature: signature)
    end

    # The content is encrypted, so it is carried through untouched and never
    # shown.
    def self.redacted_thinking(data : String) : ContentBlock
      ContentBlock.new(BlockType::RedactedThinking, text: data)
    end

    def self.image(media_type : String, data : String, source : String? = nil) : ContentBlock
      ContentBlock.new(BlockType::Image, media_type: media_type, data: data, source: source)
    end

    def self.document(media_type : String, data : String, source : String? = nil) : ContentBlock
      ContentBlock.new(BlockType::Document, media_type: media_type, data: data, source: source)
    end

    def thinking? : Bool
      @type.thinking? || @type.redacted_thinking?
    end

    def media? : Bool
      @type.image? || @type.document?
    end

    # What to call it in a message meant for a human or for the model. The
    # path if there was one, otherwise the media type — never nothing, because
    # "an attachment was removed" without saying which is not information.
    def media_label : String
      @source || @media_type || "attachment"
    end
  end

  struct Message
    include JSON::Serializable

    getter role : Role
    getter content : Array(ContentBlock)

    # True for a user message the *agent* wrote, not the user: the stop-hook
    # continuation and the output-limit continuation. Anything reasoning about
    # turn boundaries has to skip these — three of them can sit inside a single
    # real turn. Defaulted so sessions saved before the flag existed load.
    getter? synthetic : Bool = false

    # Identity, so anything that wants to point at a message can survive
    # compaction moving it. A position cannot: replacing a prefix with a
    # summary shifts every index behind it, and whoever stored one has to be
    # told. Nothing outside smith ever sees this — every provider builds its
    # request from the role and the blocks.
    #
    # Random per message rather than a counter: a fork copies a transcript, and
    # two sessions handing out the same numbers would collide. Defaulted so
    # messages saved before ids existed load and get one.
    getter id : String = Message.new_id

    def self.new_id : String
      Random::Secure.hex(8)
    end

    def initialize(
      @role : Role,
      @content : Array(ContentBlock),
      @synthetic : Bool = false,
      @id : String = Message.new_id,
    )
    end

    def self.user(text : String, synthetic : Bool = false) : Message
      Message.new(Role::User, [ContentBlock.text(text)], synthetic)
    end

    def self.assistant(text : String) : Message
      Message.new(Role::Assistant, [ContentBlock.text(text)])
    end

    def self.assistant_with_blocks(blocks : Array(ContentBlock)) : Message
      Message.new(Role::Assistant, blocks)
    end

    def self.tool_results(results : Array(ContentBlock)) : Message
      Message.new(Role::Tool, results)
    end
  end

  struct ToolSpec
    include JSON::Serializable

    getter name : String
    getter description : String
    getter parameters : JSON::Any

    def initialize(@name : String, @description : String, @parameters : JSON::Any)
    end
  end

  struct Usage
    include JSON::Serializable

    getter prompt_tokens : Int32
    getter completion_tokens : Int32
    getter total_tokens : Int32

    # Anthropic prompt caching. Defaulted here as well as in the constructor,
    # so sessions saved before these fields existed still deserialize.
    getter cache_creation_tokens : Int32 = 0
    getter cache_read_tokens : Int32 = 0

    # How big the prompt actually was. Anthropic reports the cached part
    # separately, so `prompt_tokens` alone is the *uncached remainder* — a few
    # hundred tokens on a cache hit, which is not the size of anything. Callers
    # measuring context usage want this; callers pricing a request do not,
    # because the parts are billed at different rates.
    def billed_prompt_tokens : Int32
      @prompt_tokens + @cache_read_tokens + @cache_creation_tokens
    end

    def initialize(
      @prompt_tokens : Int32 = 0,
      @completion_tokens : Int32 = 0,
      @total_tokens : Int32 = 0,
      @cache_creation_tokens : Int32 = 0,
      @cache_read_tokens : Int32 = 0,
    )
    end

    # Everything that went through the cache, written or read.
    def cached_tokens : Int32
      @cache_creation_tokens + @cache_read_tokens
    end

    def +(other : Usage) : Usage
      Usage.new(
        @prompt_tokens + other.prompt_tokens,
        @completion_tokens + other.completion_tokens,
        @total_tokens + other.total_tokens,
        @cache_creation_tokens + other.cache_creation_tokens,
        @cache_read_tokens + other.cache_read_tokens
      )
    end
  end

  class Request
    getter model : String
    getter system : String?
    getter messages : Array(Message)
    getter tools : Array(ToolSpec)?
    getter max_tokens : Int32?
    getter temperature : Float64?
    getter? stream : Bool

    # nil leaves thinking off, which is the default. Otherwise one of
    # low/medium/high/xhigh/max — how deep the model is asked to think.
    getter thinking_effort : String?

    # The pre-4.6 form, where thinking was a fixed token budget rather than an
    # effort level. Current models reject it with a 400, so it is only set when
    # someone explicitly configures it for an older model.
    getter thinking_budget : Int32?

    def initialize(
      @model : String,
      @messages : Array(Message),
      @system : String? = nil,
      @tools : Array(ToolSpec)? = nil,
      @max_tokens : Int32? = nil,
      @temperature : Float64? = nil,
      @stream : Bool = true,
      @thinking_effort : String? = nil,
      @thinking_budget : Int32? = nil,
    )
    end
  end

  # Why the model stopped, normalised across providers.
  #
  # Anthropic says end_turn/tool_use/max_tokens; the OpenAI shape — which
  # OpenAI, OpenRouter and Ollama all speak — says stop/tool_calls/length.
  enum StopReason
    EndTurn
    ToolUse
    MaxTokens
    StopSequence
    Unknown

    def self.from_raw(raw : String?) : StopReason
      case raw.try(&.strip.downcase)
      when "end_turn", "stop"       then EndTurn
      when "tool_use", "tool_calls" then ToolUse
      when "max_tokens", "length"   then MaxTokens
      when "stop_sequence"          then StopSequence
      else                               Unknown
      end
    end
  end

  class Response
    getter id : String
    getter model : String
    getter content : Array(ContentBlock)
    getter stop_reason : String?
    getter usage : Usage?

    def initialize(
      @id : String,
      @model : String,
      @content : Array(ContentBlock),
      @stop_reason : String? = nil,
      @usage : Usage? = nil,
    )
    end

    # Derived rather than mapped per adapter: every provider path already
    # carries its raw value here, so one normalisation covers all five —
    # including both streaming readers.
    def stop : StopReason
      StopReason.from_raw(@stop_reason)
    end
  end
end
