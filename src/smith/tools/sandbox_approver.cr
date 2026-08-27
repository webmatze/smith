require "./approval"
require "../sandbox"

module Smith::Tools
  # Lets a *confined* shell command through the gate without asking.
  #
  # This is the point of the sandbox rather than a shortcut past it: the gate
  # exists because a shell command can do anything, and a command that cannot
  # write outside the project or reach the paths you named as secret is no
  # longer that kind of question. Asking anyway is how a user ends up leaving
  # `--yes` on, which gives up the gate *and* everything else it protects.
  #
  # Deliberately opt-in (`[sandbox] auto_approve`). Confinement is a technical
  # fact; whether it is enough to skip the prompt is a judgement, and it is
  # the user's.
  #
  # Sits *inside* RuleApprover, exactly where PromptApprover sits, so the
  # order of authority is unchanged: a `deny` rule refuses before this is ever
  # consulted, an `allow` rule permits without it, and an `ask` rule reaches
  # the inner approver rather than this one. Only an unruled command is
  # decided here.
  class SandboxApprover < Approver
    def initialize(@sandbox : Smith::Sandbox::Strategy, @inner : Approver = AutoApprover.new)
    end

    def approve?(tool : Tool, call : CallRequest) : Bool
      return @inner.approve?(tool, call) unless covered?(tool, call)

      true
    end

    def denial_message(tool : Tool, call : CallRequest) : String
      @inner.denial_message(tool, call)
    end

    def governs?(tool : Tool) : Bool
      @inner.governs?(tool)
    end

    # Only `bash`, and only when this particular command really is confined.
    #
    # `write_file` and `edit_file` are not covered on purpose: they run inside
    # smith's own process, which no profile here applies to. Waving them
    # through would be claiming a protection that was never switched on.
    private def covered?(tool : Tool, call : CallRequest) : Bool
      return false unless tool.name == "bash"

      command = call.args["command"]?.try(&.as_s?)
      return false if command.nil? || command.strip.empty?

      @sandbox.sandboxed?(command)
    end
  end
end
