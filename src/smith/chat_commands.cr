module Smith
  enum ChatCommand
    Plan
    Normal
    Rewind
  end

  # Built-in slash commands for the interactive loop.
  #
  # These must be resolved *before* Skills::Catalog#expand_prompt runs: the
  # skill catalog claims any `/name` that matches a skill, so a skill called
  # "plan" would otherwise shadow `/plan`. Built-ins win, and that precedence
  # is documented in the README.
  module ChatCommands
    def self.parse(input : String) : ChatCommand?
      case input.strip.downcase
      when "/plan"   then ChatCommand::Plan
      when "/normal" then ChatCommand::Normal
      when "/rewind" then ChatCommand::Rewind
      end
    end
  end
end
