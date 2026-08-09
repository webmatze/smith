require "./llm/types"
require "./todos"
require "./mode"
require "./hooks"
require "./mentions"

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
  #
  # Carries raw numbers only; the renderers do the arithmetic and the wording.
  # Which stages ran is reported here rather than as new Strategy members, so
  # persisted sessions and anything reading the strategy string are unaffected.
  class HistoryCompacted < Event
    getter before_tokens : Int32
    getter after_tokens : Int32
    getter strategy : String
    getter target_tokens : Int32
    getter budget_tokens : Int32
    getter stages : Array(String)

    def initialize(
      @before_tokens : Int32,
      @after_tokens : Int32,
      @strategy : String,
      @target_tokens : Int32 = 0,
      @budget_tokens : Int32 = 0,
      @stages : Array(String) = [] of String,
    )
    end

    def reached_target? : Bool
      @target_tokens <= 0 || @after_tokens <= @target_tokens
    end

    # How much of the window came back. The number that says at a glance
    # whether a compaction did useful work — two bare token counts do not.
    def reclaimed_percent : Int32
      return 0 if @budget_tokens <= 0
      ((@before_tokens - @after_tokens) * 100.0 / @budget_tokens).round.to_i
    end
  end

  # The request cannot be brought under the budget and nothing more can be
  # reclaimed. Kept apart from TurnError for the same reason BudgetExceeded is:
  # a script driving smith has to tell "start a fresh session" apart from
  # "the provider is broken", and matching on an error string is not an
  # interface.
  class ContextExhausted < Event
    getter estimated_tokens : Int32
    getter budget_tokens : Int32
    getter reclaimed_tokens : Int32

    def initialize(@estimated_tokens : Int32, @budget_tokens : Int32, @reclaimed_tokens : Int32)
    end
  end

  # Emitted whenever the agent rewrote its plan. Carries the complete list,
  # because todo_write replaces it wholesale.
  class TodosUpdated < Event
    getter items : Array(Smith::TodoList::Item)

    def initialize(@items : Array(Smith::TodoList::Item))
    end
  end

  # The agent finished researching and wants the plan approved.
  class PlanPresented < Event
    getter plan : String

    def initialize(@plan : String)
    end
  end

  class ModeChanged < Event
    getter mode : Smith::Mode

    def initialize(@mode : Smith::Mode)
    end
  end

  # A user-configured hook ran. Worth showing: hooks are invisible policy
  # otherwise, and a blocked call is easier to understand with the culprit
  # named.
  class HookFired < Event
    getter hook_event : Smith::Hooks::Event
    getter command : String
    getter? blocked : Bool

    def initialize(@hook_event : Smith::Hooks::Event, @command : String, @blocked : Bool)
    end
  end

  # The provider answered with nothing at all — no text, no tool calls. Small
  # local models do this occasionally. The message is dropped rather than
  # recorded, since an empty assistant turn breaks the next request, but the
  # turn must not simply look like a no-op to whoever is watching.
  class EmptyResponse < Event
  end

  # A shell command that outlives its tool call — started explicitly, or moved
  # to the background when it outran its timeout.
  class BashJobStarted < Event
    getter id : String
    getter command : String

    def initialize(@id : String, @command : String)
    end
  end

  class BashJobExited < Event
    getter id : String
    getter status : String

    def initialize(@id : String, @status : String)
    end
  end

  # The model ran into its output token limit and smith asked it to carry on.
  # Worth showing: the extra provider calls would otherwise appear in the usage
  # figures with no explanation.
  class ResponseContinued < Event
    getter attempt : Int32
    getter limit : Int32

    def initialize(@attempt : Int32, @limit : Int32)
    end
  end

  # The model's own reasoning, kept clearly apart from its answer. Separate
  # event types on purpose: anything listening for assistant_text keeps working
  # unchanged whether thinking is on or off.
  class ThinkingDelta < Event
    getter text : String

    def initialize(@text : String)
    end
  end

  class ThinkingBlock < Event
    getter text : String
    getter? redacted : Bool

    def initialize(@text : String, @redacted : Bool = false)
    end
  end

  # What an @-mention actually pulled into the prompt. Emitted even when
  # everything was skipped: a mention that quietly did nothing is worse than
  # one that says why.
  class FilesMentioned < Event
    getter files : Array(Mentions::Embedded)
    getter skipped : Array(Mentions::Skip)

    def initialize(@files : Array(Mentions::Embedded), @skipped : Array(Mentions::Skip))
    end
  end

  # The run stopped because it reached its cost ceiling, not because it
  # finished or failed. Kept apart from TurnError so an automated caller can
  # tell "too expensive" from "broken".
  class BudgetExceeded < Event
    getter spent_usd : Float64
    getter limit_usd : Float64

    def initialize(@spent_usd : Float64, @limit_usd : Float64)
    end
  end

  alias Listener = Proc(Event, Nil)
end
