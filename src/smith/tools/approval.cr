require "json"
require "./tool"
require "./permissions"

module Smith::Tools
  # Decides whether a mutating tool call may run. Kept as an interface so the
  # registry — and with it the agent loop — stays free of any UI concern.
  abstract class Approver
    abstract def approve?(tool : Tool, call : CallRequest) : Bool

    # Shown to the LLM as the tool result when a call is refused, so the model
    # can see the blockage in the transcript and choose another route.
    def denial_message(tool : Tool, call : CallRequest) : String
      "Tool '#{tool.name}' was denied by the user."
    end

    # Whether this approver could refuse the tool on its own account. Read-only
    # tools skip the gate entirely unless something here says otherwise.
    def governs?(tool : Tool) : Bool
      false
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

    def denial_message(tool : Tool, call : CallRequest) : String
      "Tool '#{tool.name}' requires approval, but smith is running without an " \
      "interactive terminal. Re-run with --yes to allow mutating tools."
    end
  end

  # Plan mode. Refuses every mutating tool without asking — the point of plan
  # mode is that nothing changes until the user has seen a plan, so there is
  # nothing to prompt about.
  #
  # `bash` is blocked wholesale rather than only for writing commands: telling
  # a reading shell command from a writing one is not reliably decidable (see
  # the caveats on AllowList below).
  class PlanApprover < Approver
    def approve?(tool : Tool, call : CallRequest) : Bool
      false
    end

    def denial_message(tool : Tool, call : CallRequest) : String
      "Tool '#{tool.name}' is unavailable in plan mode. Research the codebase " \
      "with read_file/grep/glob and call exit_plan_mode with your plan when ready."
    end
  end

  # Asks the user, remembering [a]lways answers for the rest of the session.
  class PromptApprover < Approver
    getter allowlist : Array(String)

    def initialize(
      @allowlist : Array(String) = Array(String).new,
      @input : IO = STDIN,
      @output : IO = STDOUT,
      @rules : RuleSet = RuleSet.new,
    )
      @remembered = Array(Rule).new
    end

    def approve?(tool : Tool, call : CallRequest) : Bool
      return true if remembered?(tool, call)
      return true if tool.name == "bash" && allowlisted_command?(call)

      ask(tool, call)
    end

    # An [a]lways answer used to cover the whole tool for the rest of the
    # session — one confirmed write_file and every path was open. It now
    # remembers the narrow rule that was actually shown.
    private def remembered?(tool : Tool, call : CallRequest) : Bool
      @remembered.any? { |rule| rule.matches?(tool.name, call.args, @rules.project_dir, all: true) }
    end

    private def allowlisted_command?(call : CallRequest) : Bool
      command = call.args["command"]?.try(&.as_s?)
      return false if command.nil?

      AllowList.allows?(command, @allowlist)
    end

    private def ask(tool : Tool, call : CallRequest) : Bool
      suggestion = @rules.suggest(tool.name, call.args)

      loop do
        @output.puts "\n\e[33m⚠️  Approval required\e[0m"
        @output.puts "   Tool: \e[1m#{tool.name}\e[0m"
        @output.puts "   #{summarize(call)}"
        @output.print "   Allow? [y]es / [n]o / [a]lways allow `#{suggestion}`: "
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
          if rule = Rule.parse(suggestion)
            @remembered << rule
          end
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

  # Applies the configured rules, then hands anything they do not settle to an
  # inner approver.
  #
  # Wrapping rather than extending is what makes a deny rule survive `--yes`:
  # the flag only replaces the *inner* approver, and deny is decided before the
  # inner one is ever consulted. The same ordering keeps a session-wide
  # [a]lways from reaching past a deny rule.
  class RuleApprover < Approver
    getter rules : RuleSet
    getter inner : Approver

    def initialize(@rules : RuleSet, @inner : Approver = AutoApprover.new)
    end

    def approve?(tool : Tool, call : CallRequest) : Bool
      case @rules.decide(tool.name, call.args)
      in Decision::Deny  then false
      in Decision::Allow then true
      in Decision::Ask, Decision::Unset
        @inner.approve?(tool, call)
      end
    end

    def denial_message(tool : Tool, call : CallRequest) : String
      if @rules.decide(tool.name, call.args).deny?
        return "Tool '#{tool.name}' is blocked by the deny rule `#{denying_rule(tool, call)}`. " \
               "This cannot be overridden at runtime; the rule lives in the [approval] config."
      end

      @inner.denial_message(tool, call)
    end

    def governs?(tool : Tool) : Bool
      @rules.governs?(tool.name) || @inner.governs?(tool)
    end

    private def denying_rule(tool : Tool, call : CallRequest) : String
      @rules.matching_deny(tool.name, call.args) || "#{tool.name}(...)"
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
    # Shared with the rule engine, which applies the same segmentation before
    # matching a pattern against each part.
    def self.segments(command : String) : Array(String)
      command.split(SEPARATORS).map(&.strip).reject(&.empty?)
    end

    def self.allows?(command : String, allowlist : Array(String)) : Bool
      return false if allowlist.empty?

      segments = segments(command)
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
