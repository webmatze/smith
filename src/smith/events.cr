require "./llm/types"
require "./todos"

module Smith::Events
  abstract class Event
  end

  class AssistantText < Event
    getter text : String

    def initialize(@text : String)
    end
  end

  # A single incremental piece of assistant text. Emitted for every provider —
  # non-streaming ones deliver the whole block as one delta — so consumers
  # never need to special-case whether streaming is active.
  class AssistantTextDelta < Event
    getter text : String

    def initialize(@text : String)
    end
  end

  class ToolStart < Event
    getter tool_call_id : String
    getter tool_name : String
    getter args : JSON::Any

    def initialize(@tool_call_id : String, @tool_name : String, @args : JSON::Any)
    end
  end

  class ToolFinished < Event
    getter tool_call_id : String
    getter tool_name : String
    getter result : String
    getter is_error : Bool

    def initialize(@tool_call_id : String, @tool_name : String, @result : String, @is_error : Bool = false)
    end
  end

  class UsageUpdated < Event
    getter usage : Smith::LLM::Usage

    def initialize(@usage : Smith::LLM::Usage)
    end
  end

  class TurnCompleted < Event
    getter turns : Int32

    def initialize(@turns : Int32)
    end
  end

  class TurnError < Event
    getter error : String

    def initialize(@error : String)
    end
  end

  # Emitted when the transcript was shrunk to stay inside the context window,
  # so a user never silently wonders where their context went.
  class HistoryCompacted < Event
    getter before_tokens : Int32
    getter after_tokens : Int32
    getter strategy : String

    def initialize(@before_tokens : Int32, @after_tokens : Int32, @strategy : String)
    end
  end

  # Emitted whenever the agent rewrote its plan. Carries the complete list,
  # because todo_write replaces it wholesale.
  class TodosUpdated < Event
    getter items : Array(Smith::TodoList::Item)

    def initialize(@items : Array(Smith::TodoList::Item))
    end
  end

  alias Listener = Proc(Event, Nil)
end
