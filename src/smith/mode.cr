module Smith
  # What the main thread is allowed to do. `Plan` is research-only: every
  # mutating tool is refused until the user has seen and approved a plan.
  enum Mode
    Normal
    Plan

    # Used for `--plan`, `SMITH_MODE` and `[defaults] mode`. Anything
    # unrecognised falls back to Normal rather than failing the run — same
    # forgiving rule the rest of the config chain follows.
    def self.from_string(str : String) : Mode
      str.strip.downcase == "plan" ? Plan : Normal
    end
  end
end
