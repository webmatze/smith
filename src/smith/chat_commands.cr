module Smith
  enum ChatCommand
    Plan
    Normal
    Rewind
    Context
    Rename
    Help
    Clear
    Sessions
    Resume
    Model
    Quit
  end

  # Built-in slash commands for the interactive loop.
  #
  # These must be resolved *before* Skills::Catalog#expand_prompt runs: the
  # skill catalog claims any `/name` that matches a skill, so a skill called
  # "plan" would otherwise shadow `/plan`. Built-ins win, and that precedence
  # is documented in the README.
  #
  # The DEFINITIONS table is the single source of truth for parsing, for
  # `/help` and for the TUI's autocomplete popup — the three must not drift.
  module ChatCommands
    # How a command relates to its argument. `/model` is why the middle case
    # exists: bare it reports the model in use, with a name it switches.
    enum Arity
      None
      Optional
      Required
    end

    record Invocation, command : ChatCommand, argument : String? = nil

    # One row of the command table. `argument` names an expected argument
    # ("/rename <name>") or is nil for bare commands; `arity` says whether one
    # may be given at all, and whether the command is meaningless without it.
    record Definition,
      command : ChatCommand,
      verb : String,
      description : String,
      argument : String? = nil,
      arity : Arity = Arity::None do
      def requires_argument : Bool
        arity.required?
      end

      def takes_argument? : Bool
        !arity.none?
      end

      # What `/help` shows: an optional argument is bracketed, so the one
      # command that works both ways says so.
      def usage : String
        arg = @argument
        return @verb if arg.nil?

        arity.optional? ? "#{@verb} [#{arg}]" : "#{@verb} #{arg}"
      end
    end

    DEFINITIONS = [
      Definition.new(ChatCommand::Plan, "/plan", "Switch to plan mode (research only)"),
      Definition.new(ChatCommand::Normal, "/normal", "Leave plan mode"),
      Definition.new(ChatCommand::Clear, "/clear", "Clear the context and the screen"),
      Definition.new(ChatCommand::Context, "/context", "Show where the context window goes"),
      Definition.new(ChatCommand::Rewind, "/rewind", "Undo this session back to its start"),
      Definition.new(ChatCommand::Sessions, "/sessions", "List saved sessions"),
      Definition.new(ChatCommand::Resume, "/resume", "Switch to another session", argument: "<session>", arity: Arity::Required),
      Definition.new(ChatCommand::Rename, "/rename", "Rename the current session", argument: "<name>", arity: Arity::Required),
      Definition.new(ChatCommand::Model, "/model", "Show the model in use, or switch to another", argument: "<name>", arity: Arity::Optional),
      Definition.new(ChatCommand::Help, "/help", "Show this list"),
      Definition.new(ChatCommand::Quit, "/quit", "End the session"),
    ]

    def self.definitions : Array(Definition)
      DEFINITIONS
    end

    def self.parse(input : String) : Invocation?
      stripped = input.strip
      return nil unless stripped.starts_with?('/')

      verb, _, rest = stripped.partition(' ')
      argument = rest.strip
      argument = nil if argument.empty?

      definition = DEFINITIONS.find { |d| d.verb == verb.downcase }
      return nil if definition.nil?

      if argument
        # Arguments are how a skill invocation looks (`/deploy staging`), so a
        # built-in claims the argument form only when it has a use for one.
        definition.takes_argument? ? Invocation.new(definition.command, argument) : nil
      else
        # Without its argument there is nothing to do, and the skill catalog
        # may as well have the bare form.
        definition.requires_argument ? nil : Invocation.new(definition.command)
      end
    end
  end
end
