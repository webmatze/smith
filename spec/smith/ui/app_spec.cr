require "./support/screen"

include Smith::UI

# A minimal tool double for the approver specs.
private class FakeTool < Smith::Tools::Tool
  def name : String
    "fake"
  end

  def description : String
    "test double"
  end

  def parameters : JSON::Any
    JSON.parse("{}")
  end

  def run(args : JSON::Any) : String
    "ok"
  end

  include Smith::Tools::MutatingTool
end

# The screen as it stood while an over-long approval modal was up: the frame
# is captured before the answer is processed, since the next draw takes the
# live region down again and teardown wipes it for good.
private def modal_frame_lines(script : Array, width = 80, height = 24) : Array(String)
  app = app_with(script, width: width, height: height)
  body = Array(StyledLine).new
  40.times { |i| body << LineUtil.line("argument line #{i}") }
  frame = ""

  app.run do |_|
    spawn do
      app.modal("Approval required", body, [{'y', "allow once"}], ['y'])
      frame = app.terminal.io.as(IO::Memory).to_s
      app.turn_finished
    end
  end

  Screen.replay(frame, width: width, height: height).screen_lines
end

describe Smith::UI::App do
  describe "the prompt loop" do
    it "submits typed text and returns to the prompt" do
      app = app_with(["hi\r", :tick, "quit\r"])

      app.run do |text|
        if text == "hi"
          app.add_block(AssistantBlock.new("hello!", live: false), finalize: true)
          app.turn_finished
        else
          app.quit
        end
      end

      kinds = app.blocks.map(&.class)
      kinds.should eq([UserBlock, AssistantBlock, UserBlock])
      app.blocks[0].as(UserBlock).lines(80)
        .map { |l| LineUtil.plain(l) }.join.should contain("hi")
    end

    it "ends on Ctrl+C with an empty editor" do
      app = app_with(["\x03"])
      submitted = false
      app.run { |_| submitted = true }
      submitted.should be_false
    end

    it "clears the editor on Ctrl+C when there is text" do
      app = app_with(["ab\x03", "\r"])
      app.run { |_| }
      app.editor.empty?.should be_true
    end

    it "clears the editor on Escape" do
      app = app_with(["ab\e", :tick, "\r"])
      app.run { |_| }
      app.editor.empty?.should be_true
    end

    it "does not submit blank input" do
      app = app_with(["   \r", :tick, "x\r"])
      seen = [] of String
      app.run { |text| seen << text }
      seen.should eq(["x"])
    end

    it "records a submitted prompt in the history Up walks" do
      # Enter goes through the editor, which is the only thing that files a
      # prompt into the history — handling it beside the editor left Up/Down
      # walking a list nothing ever wrote to.
      app = app_with(["first\r", :tick, "\e[A", :tick])

      app.run { |_| app.turn_finished }

      app.editor.history.should eq(["first"])
      app.editor.text.should eq("first")
    end

    it "keeps blank input out of the history" do
      app = app_with(["   \r", :tick, "\e[A", :tick])

      app.run { |_| app.turn_finished }

      app.editor.history.should be_empty
      app.editor.text.should eq("")
    end

    it "draws the status bar into the terminal output" do
      app = app_with(["\x03"])
      app.model_name = "claude-test"
      app.run { |_| }

      output = app.terminal.io.as(IO::Memory).to_s
      output.should contain("claude-test")
      output.should contain("normal")
    end
  end

  describe "interrupts during a turn" do
    it "calls on_interrupt once, then on_abort on a quick second press" do
      app = app_with(["go\r", :tick, "\e", :tick, "\e", :tick])
      interrupts = 0
      aborts = 0

      app.on_interrupt { interrupts += 1 }
      app.on_abort { aborts += 1 }

      app.run do |_|
        spawn { sleep(1.second); app.turn_finished }
      end

      interrupts.should eq(1)
      aborts.should eq(1)
    end

    it "sets a stopping hint in the status bar after the first interrupt" do
      app = app_with(["go\r", :tick, "\e", :tick, "\e"])
      app.on_interrupt { }
      app.on_abort { }

      app.run { |_| spawn { sleep(1.second); app.turn_finished } }

      output = app.terminal.io.as(IO::Memory).to_s
      output.should contain("stopping")
    end

    it "redraws from scratch on Ctrl+L while a turn runs" do
      # A garbled screen is likeliest mid-turn, which is exactly when the
      # state machine used to swallow ^L.
      app = app_with(["go\r", :tick, "\x0c", :tick, "\e", :tick, "\e"])
      app.on_interrupt { }
      app.on_abort { }

      app.run { |_| spawn { sleep(1.second); app.turn_finished } }

      app.terminal.io.as(IO::Memory).to_s.should contain("\e[2J")
    end

    it "ignores other keys while a turn runs" do
      app = app_with(["go\r", :tick, "xyz", :tick, "\e", :tick, "\e"])
      interrupted = false
      app.on_interrupt { interrupted = true }
      app.on_abort { }

      app.run { |_| spawn { sleep(1.second); app.turn_finished } }

      interrupted.should be_true
      app.editor.text.should eq("")
    end
  end

  describe "character modals" do
    it "answers a modal from the turn fiber" do
      app = app_with(["go\r", :tick, "y", :tick])
      answer = '\u0000'

      app.run do |_|
        spawn do
          answer = app.modal("Approve?", [] of StyledLine, [{'y', "yes"}, {'n', "no"}], ['y', 'n'])
          app.turn_finished
        end
      end

      answer.should eq('y')
      app.state.idle?.should be_true
    end

    it "answers Escape as cancel" do
      app = app_with(["go\r", :tick, "\e", :tick])
      answer = 'x'

      app.run do |_|
        spawn do
          answer = app.modal("Approve?", [] of StyledLine, [{'y', "yes"}], ['y'])
          app.turn_finished
        end
      end

      answer.should eq('\e')
    end

    it "ignores keys the modal does not offer" do
      app = app_with(["go\r", :tick, "q", :tick, "n"])
      answer = 'x'

      app.run do |_|
        spawn do
          answer = app.modal("Approve?", [] of StyledLine, [{'y', "yes"}, {'n', "no"}], ['y', 'n'])
          app.turn_finished
        end
      end

      answer.should eq('n')
    end

    it "keeps a tall modal inside the screen instead of reprinting it every tick" do
      # A live region taller than the terminal cannot be redrawn in place —
      # cursor_up stops at the top row — so an unclamped region left a fresh
      # copy of itself in the scrollback on every tick.
      app = app_with(["go\r", :tick, :tick, :tick, :tick, "y", :tick, :tick], width: 80, height: 24)
      body = Array(StyledLine).new
      40.times { |i| body << LineUtil.line("argument line #{i}") }
      frame = ""

      app.run do |_|
        spawn do
          tool = ToolBlock.new("c1", "bash", "sleep 30")
          app.add_block(tool)
          app.modal("Approval required", body, [{'y', "allow once"}], ['y'])
          # Everything written while the modal was up — the next draw takes
          # the region back down, and teardown wipes it entirely.
          frame = app.terminal.io.as(IO::Memory).to_s
          tool.status = ToolBlock::Status::Done
          app.turn_finished
        end
      end

      # Clamped, not reprinted: redrawn in place, so no copy of the panel was
      # ever pushed off the top.
      Screen.replay(frame).scrollback.count(&.includes?("Approval required")).should eq(0)
      screen = Screen.replay(app.terminal.io.as(IO::Memory).to_s)
      screen.all_lines.count(&.includes?("sleep 30")).should eq(1)
    end

    it "shows the modal's question even when its body does not fit" do
      lines = modal_frame_lines(["go\r", :tick, :tick, "y"])
      visible = lines.join("\n")

      # The question is pinned: it is what the choices below it refer to, so
      # dropping it first would ask the human to approve an unnamed thing.
      visible.should contain("Approval required")
      visible.should contain("more lines above")
      visible.should contain("[y] allow once")
      # The tail of the body — the part next to the question — survives.
      visible.should contain("argument line 39")
    end

    it "keeps the question on a screen too small for the panel" do
      # Six rows cannot hold question, body, choices and status bar together.
      # What has to go is the body — never the question the choices answer.
      lines = modal_frame_lines(["go\r", :tick, :tick, "y"], height: 6)
      visible = lines.join("\n")

      visible.should contain("Approval required")
      visible.should contain("[y] allow once")
    end

    it "pins the question above the body it belongs to" do
      lines = modal_frame_lines(["go\r", :tick, :tick, "y"])

      title = lines.index(&.includes?("Approval required")).not_nil!
      marker = lines.index(&.includes?("more lines above")).not_nil!
      tail = lines.index(&.includes?("argument line 39")).not_nil!

      title.should be < marker
      marker.should be < tail
    end

    it "renders the modal body while it is up" do
      app = app_with(["go\r", :tick, "y"])
      body = [LineUtil.line("rm -rf /")]

      app.run do |_|
        spawn do
          app.modal("Danger", body, [{'y', "yes"}], ['y'])
          app.turn_finished
        end
      end

      output = app.terminal.io.as(IO::Memory).to_s
      output.should contain("Danger")
      output.should contain("rm -rf /")
      output.should contain("[y] yes")
    end
  end

  describe "text modals" do
    it "collects a typed answer" do
      app = app_with(["go\r", :tick, "n", :tick, "revise this\r", :tick])
      feedback = ""

      app.run do |_|
        spawn do
          char = app.modal("Plan?", [] of StyledLine, [{'y', "ok"}, {'n', "feedback"}], ['y', 'n'])
          feedback = app.modal_text("Feedback", [] of StyledLine) if char == 'n'
          app.turn_finished
        end
      end

      feedback.should eq("revise this")
    end

    it "keeps the modal editor separate from the prompt editor" do
      app = app_with(["go\r", :tick, "n", :tick, "note\r", :tick, "hello\r"])
      seen = [] of String

      app.run do |text|
        seen << text
        spawn do
          char = app.modal("Plan?", [] of StyledLine, [{'n', "feedback"}], ['n'])
          app.modal_text("Feedback", [] of StyledLine) if char == 'n'
          app.turn_finished
        end
      end

      # "note" went to the modal; the prompt got "go" and "hello".
      seen.should eq(["go", "hello"])
      app.editor.empty?.should be_true
    end
  end

  describe "modal_sync" do
    it "runs its own key loop for pre-session decisions" do
      app = app_with(["y"])

      answer = app.modal_sync("Trust?", [] of StyledLine, [{'y', "trust"}, {'n', "refuse"}], ['y', 'n'])

      answer.should eq('y')
    end

    it "treats EOF and Escape as a refusal" do
      app = app_with([] of Symbol | String)

      answer = app.modal_sync("Trust?", [] of StyledLine, [{'y', "trust"}], ['y'])

      answer.should eq('\e')
    end
  end
end

describe Smith::UI::TuiApprover do
  it "asks via a modal and honors the answer" do
    app = app_with(["go\r", :tick, "n", :tick])
    results = [] of Bool

    app.run do |_|
      spawn do
        approver = TuiApprover.new(app)
        results << approver.approve?(FakeTool.new, Smith::Tools::CallRequest.new("c1", "fake", JSON.parse("{}")))
        app.turn_finished
      end
    end

    results.should eq([false])
  end

  it "remembers an always answer for later calls" do
    app = app_with(["go\r", :tick, "a", :tick])
    results = [] of Bool

    app.run do |_|
      spawn do
        approver = TuiApprover.new(app)
        call = Smith::Tools::CallRequest.new("c1", "fake", JSON.parse("{}"))
        results << approver.approve?(FakeTool.new, call)
        # Second call must not open another modal — the script is empty, so a
        # second prompt would leave the answer stuck at its default.
        results << approver.approve?(FakeTool.new, call)
        app.turn_finished
      end
    end

    results.should eq([true, true])
  end

  it "lets an allowlisted bash command through without asking" do
    app = app_with([] of Symbol | String)
    approver = TuiApprover.new(app, allowlist: ["ls"])

    bash = Smith::Tools::Registry.default.get("bash").not_nil!
    call = Smith::Tools::CallRequest.new("c1", "bash", JSON.parse(%({"command": "ls -la"})))
    approver.approve?(bash, call).should be_true
  end
end

describe Smith::UI::TuiPlanGate do
  it "approves on y" do
    app = app_with(["go\r", :tick, "y", :tick])
    verdict = Smith::PlanVerdict.halted

    app.run do |_|
      spawn do
        verdict = TuiPlanGate.new(app).review("the plan")
        app.turn_finished
      end
    end

    verdict.decision.should eq(Smith::PlanDecision::Approved)
  end

  it "halts on escape" do
    app = app_with(["go\r", :tick, "\e", :tick])
    verdict = Smith::PlanVerdict.approved

    app.run do |_|
      spawn do
        verdict = TuiPlanGate.new(app).review("the plan")
        app.turn_finished
      end
    end

    verdict.decision.should eq(Smith::PlanDecision::Halted)
  end

  it "collects rejection feedback as text" do
    app = app_with(["go\r", :tick, "n", :tick, "split step two\r", :tick])
    verdict = Smith::PlanVerdict.halted

    app.run do |_|
      spawn do
        verdict = TuiPlanGate.new(app).review("the plan")
        app.turn_finished
      end
    end

    verdict.decision.should eq(Smith::PlanDecision::Rejected)
    verdict.feedback.should eq("split step two")
  end
end
