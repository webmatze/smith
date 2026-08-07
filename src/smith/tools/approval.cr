require "json"
require "./tool"

module Smith::Tools
  # Decides whether a mutating tool call may run. Kept as an interface so the
  # registry — and with it the agent loop — stays free of any UI concern.
  abstract class Approver
    abstract def approve?(tool : Tool, call : CallRequest) : Bool

    # Shown to the LLM as the tool result when a call is refused, so the model
    # can see the blockage in the transcript and choose another route.
    def denial_message(tool : Tool) : String
      "Tool '#{tool.name}' was denied by the user."
    end
  end

  # Runs everything. Used by --yes, by `mode = "auto"`, and as the library
  # default so Registry stays usable without a human attached.
  class AutoApprover < Approver
    def approve?(tool : Tool, call : CallRequest) : Bool
      true
    end
  end

  # Refuses everything. Used in headless mode, where there is nobody to ask.
  class DenyApprover < Approver
    def approve?(tool : Tool, call : CallRequest) : Bool
      false
    end

    def denial_message(tool : Tool) : String
      "Tool '#{tool.name}' requires approval, but smith is running without an " \
      "interactive terminal. Re-run with --yes to allow mutating tools."
    end
  end

  # Asks the user, remembering [a]lways answers for the rest of the session.
  class PromptApprover < Approver
    getter allowlist : Array(String)

    def initialize(
      @allowlist : Array(String) = Array(String).new,
      @input : IO = STDIN,
      @output : IO = STDOUT,
    )
      @always_allowed = Set(String).new
    end

    def approve?(tool : Tool, call : CallRequest) : Bool
      return true if @always_allowed.includes?(tool.name)
      return true if tool.name == "bash" && allowlisted_command?(call)

      ask(tool, call)
    end

    private def allowlisted_command?(call : CallRequest) : Bool
      command = call.args["command"]?.try(&.as_s?)
      return false if command.nil?

      AllowList.allows?(command, @allowlist)
    end

    private def ask(tool : Tool, call : CallRequest) : Bool
      loop do
        @output.puts "\n\e[33m⚠️  Approval required\e[0m"
        @output.puts "   Tool: \e[1m#{tool.name}\e[0m"
        @output.puts "   #{summarize(call)}"
        @output.print "   Allow? [y]es / [n]o / [a]lways allow #{tool.name}: "
        @output.flush

        answer = @input.gets

        # EOF — nobody is there to answer, so refuse rather than assume yes.
        return false if answer.nil?

        case answer.strip.downcase
        when "y", "yes"
          return true
        when "n", "no", ""
          return false
        when "a", "always"
          @always_allowed << tool.name
          return true
        else
          @output.puts "   Please answer y, n or a."
        end
      end
    end

    private def summarize(call : CallRequest) : String
      if command = call.args["command"]?.try(&.as_s?)
        "Command: #{command}"
      elsif path = call.args["path"]?.try(&.as_s?)
        "Path: #{path}"
      else
        "Arguments: #{call.args.to_json}"
      end
    end
  end

  # Matching for the [approval] allowlist.
  module AllowList
    # Shell metacharacters. The command is split on these and *every* resulting
    # segment must match the allowlist on its own.
    SEPARATORS = /\$\(|[;&|`><\n)]/

    # Splitting only ever produces more and smaller segments, never a larger
    # one, so injected code can never hide inside an allowed prefix — it always
    # becomes its own segment that must itself be listed.
    #
    # This is deliberately not a shell parser: metacharacters inside quotes are
    # split too, so `echo "hi; there"` falls through to the prompt. That errs
    # towards asking too often, never towards allowing too much.
    def self.allows?(command : String, allowlist : Array(String)) : Bool
      return false if allowlist.empty?

      segments = command.split(SEPARATORS).map(&.strip).reject(&.empty?)
      return false if segments.empty?

      segments.all? do |segment|
        allowlist.any? do |entry|
          stripped = entry.strip
          next false if stripped.empty?
          segment == stripped || segment.starts_with?("#{stripped} ")
        end
      end
    end
  end
end
