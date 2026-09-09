require "./events"
require "./notify"

module Smith
  # The first consumer of `Smith::Notify`: it listens to a run and turns "this
  # turn is over" into one notification.
  #
  # A listener of its own rather than a fourth renderer, because which
  # renderer is showing the run is irrelevant to whether one should go out — a
  # `--json` caller and a fullscreen one are equally served by being told when
  # to look back — and because a renderer owns the exit code and the failure
  # state of the run, which this has no business deciding.
  #
  # Attached in `CLI#build_agent`, the one place every route to a main-thread
  # agent passes through, so the plain loop, the fullscreen one, `run`,
  # `resume` and a mid-session `/resume` all notify without any of them having
  # to know.
  #
  # A subagent is deliberately left out, and not by a check for it: children
  # are built by `Subagents::Supervisor` with `Agent.new` of its own and given
  # their own listener, so they never meet this one. That is also the right
  # answer — a delegate that announced each child as it finished would be
  # noise where the parent's own completion is the signal. cmux agrees, to the
  # extent that it suppresses subagent completions of its own agents; note that
  # its `CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS` governs events cmux derives from
  # the wrappers it installs for Claude Code and Codex, not anything posted
  # over the socket, so smith cannot lean on it here.
  #
  # It fires on every turn rather than only on long ones, and deliberately does
  # not try to guess whether anybody is watching: cmux already withdraws the
  # banner of a workspace that has become visible, so the decision belongs to
  # the terminal that knows its own focus — which is the one thing this cannot
  # see from inside.
  class TurnNotifier
    # A body is read at a glance, from another tab, while deciding whether to
    # switch back. What does not fit that is not a body: a model's closing
    # answer runs to pages, and a notification carrying three of them is one
    # nobody reads.
    #
    # Smith's own limit — cmux documents a title, a subtitle and a body
    # without a length on any of them, so nothing here is imposed by the
    # terminal. Cut at a word boundary and marked as cut, rather than sent
    # whole or dropped: the reader should get the sentence the run ended on
    # and be told there is more.
    MAX_BODY = 200

    def initialize(@notify : Notify, @subtitle : String? = nil)
      @text = ""
    end

    def handle(event : Events::Event) : Nil
      case event
      when Events::AssistantText
        # Collected rather than sent: one response can carry several text
        # blocks, and only what the last one said is the answer.
        @text += event.text
      when Events::ToolStart
        # Text before a tool call was an announcement — "let me look at that
        # file" — not an answer. Dropped, so a run that ends among its tools
        # reports no body rather than a stale promise of one.
        @text = ""
      when Events::TurnCompleted
        announce
      when Events::TurnError, Events::BudgetExceeded, Events::ContextExhausted
        # A run can end on any of these instead of a completed turn — a
        # provider that failed, a budget that ran out, a window that filled.
        # Whatever text was collected belongs to the run that just died, and
        # left standing it would be prefixed to the next turn's answer.
        @text = ""
      end
    end

    # The turn is over. Title names who, subtitle names where, and the body
    # says what came out — the three fields `cmux notify` documents, and
    # nothing beyond them: what else a payload may carry is a question for the
    # wire, which does not exist yet (#120).
    private def announce : Nil
      begin
        @notify.notify("Smith", subtitle: @subtitle, body: body)
      ensure
        # The text belonged to the turn that just ended. Left standing it would
        # be prefixed to the next one's answer, and a session of four turns
        # would notify four times with the fourth body holding all four.
        @text = ""
      end
    end

    # One line of prose, cut at a word boundary. Whitespace is collapsed
    # because a model's answer usually starts with a paragraph, and a body
    # carrying twelve newlines reads as a gap rather than as a message.
    private def body : String?
      collapsed = @text.gsub(/\s+/, " ").strip
      return nil if collapsed.empty?
      return collapsed if collapsed.size <= MAX_BODY

      cut = collapsed[0, MAX_BODY]
      if (space = cut.rindex(' ')) && space > MAX_BODY // 2
        cut = cut[0, space]
      end

      "#{cut}…"
    end
  end
end
