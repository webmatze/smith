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
    end

    getter type : BlockType
    getter text : String?
    getter tool_call_id : String?
    getter tool_name : String?
    getter tool_args : JSON::Any?
    getter is_error : Bool?

    def initialize(@type : BlockType, @text : String? = nil, @tool_call_id : String? = nil, @tool_name : String? = nil, @tool_args : JSON::Any? = nil, @is_error : Bool? = nil)
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
  end

  struct Message
    include JSON::Serializable

    getter role : Role
    getter content : Array(ContentBlock)

    def initialize(@role : Role, @content : Array(ContentBlock))
    end

    def self.user(text : String) : Message
      Message.new(Role::User, [ContentBlock.text(text)])
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

    def initialize(@prompt_tokens : Int32 = 0, @completion_tokens : Int32 = 0, @total_tokens : Int32 = 0)
    end
  end

  class Request
    getter model : String
    getter system : String?
    getter messages : Array(Message)
    getter tools : Array(ToolSpec)?
    getter max_tokens : Int32?
    getter temperature : Float64?

    def initialize(
      @model : String,
      @messages : Array(Message),
      @system : String? = nil,
      @tools : Array(ToolSpec)? = nil,
      @max_tokens : Int32? = nil,
      @temperature : Float64? = nil,
    )
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
  end
end
