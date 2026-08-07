require "json"
require "./tool"
require "../todos"

module Smith::Tools
  # Thin wrapper around a TodoList. Neither parallel-safe (it writes shared
  # state) nor mutating (nothing outside smith changes, so no approval gate).
  class TodoWrite < Tool
    def initialize(@todos : Smith::TodoList)
    end

    def name : String
      "todo_write"
    end

    def description : String
      <<-DESC
      Record and update the plan for a multi-step task. Use it as soon as a task needs more than one step, and update it immediately after finishing each step — do not batch updates.

      Every call replaces the complete list, so always send all items, not just the changed ones.

      Rules:
        • Exactly one item may have status "in_progress"; more are rejected.
        • Mark an item "completed" only once it is really done.
        • Send an empty list when the plan is finished or dropped.
        • Phrase content in imperative form, e.g. "Add streaming to Ollama provider".
      DESC
    end

    def parameters : JSON::Any
      JSON.parse(%({
        "type": "object",
        "properties": {
          "todos": {
            "type": "array",
            "description": "The complete todo list, replacing any previous one.",
            "items": {
              "type": "object",
              "properties": {
                "content": {
                  "type": "string",
                  "description": "Imperative form, e.g. 'Add streaming to Ollama provider'"
                },
                "status": {
                  "type": "string",
                  "enum": ["pending", "in_progress", "completed"]
                }
              },
              "required": ["content", "status"]
            }
          }
        },
        "required": ["todos"]
      }))
    end

    def run(args : JSON::Any) : String
      raw = args["todos"]?
      return "Error: 'todos' argument is required (an array of {content, status} objects)." if raw.nil?

      items = begin
        Array(Smith::TodoList::Item).from_json(raw.to_json)
      rescue ex : JSON::SerializableError | JSON::ParseException
        return "Error: invalid todo item — each entry needs a 'content' string and a 'status' of pending, in_progress or completed (#{ex.message})."
      end

      @todos.replace(items)
      "Todos updated: #{@todos.summary}."
    end
  end
end
