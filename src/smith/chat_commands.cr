module Smith
  enum ChatCommand
    Plan
    Normal
    Rewind
    Context
    Rename
  end

  # Built-in slash commands for the interactive loop.
  #
  # These must be resolved *before* Skills::Catalog#expand_prompt runs: the
  # skill catalog claims any `/name` that matches a skill, so a skill called
  # "plan" would otherwise shadow `/plan`. Built-ins win, and that precedence
  # is documented in the README.
  module ChatCommands
    record Invocation, command : ChatCommand, argument : String? = nil

    def self.parse(input : String) : Invocation?
      stripped = input.strip
      return nil unless stripped.starts_with?('/')

      verb, _, rest = stripped.partition(' ')
      argument = rest.strip
      argument = nil if argument.empty?

      case verb.downcase
      when "/rename"
        # The one built-in that takes an argument; without one there is
        # nothing to do and the skill catalog may as well have it.
        argument ? Invocation.new(ChatCommand::Rename, argument) : nil
      when "/plan", "/normal", "/rewind", "/context"
        # Arguments are how a skill invocation looks (`/deploy staging`), so a
        # built-in only claims the bare form.
        next_command(verb.downcase) if argument.nil?
      end
    end

    private def self.next_command(verb : String) : Invocation
      command = case verb
                when "/plan"   then ChatCommand::Plan
                when "/normal" then ChatCommand::Normal
                when "/rewind" then ChatCommand::Rewind
                else                ChatCommand::Context
                end

      Invocation.new(command)
    end
  end
end
