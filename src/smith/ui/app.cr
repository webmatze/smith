require "anvil"
require "./style"
require "./view_model"
require "./completions"
require "../todos"
require "../mode"
require "../plan"

module Smith::UI
  # The fullscreen controller.
  #
  # The machinery — the event loop, the live region, committing finished
  # blocks into the scrollback, the modal channels — comes from `Anvil::App`.
  # What lives here is what is smith's own: which keys mean what while a
  # prompt is open, how the status bar reads, and what the slash-command
  # popup does to the keys it owns.
  #
  # Rendering model (same as Claude Code): finished blocks are flushed into
  # the normal scrollback once; the live region at the bottom — streaming
  # text, running tools, status bar, input — is redrawn in place whenever
  # something changes. No alternate screen, so the transcript stays in the
  # terminal's scrollback and can be copied and searched like any other output.
  class App
    alias State = Anvil::App::State

    getter anvil : Anvil::App

    property model_name : String = ""
    property mode : Smith::Mode = Smith::Mode::Normal
    property usage_text : String = ""
    property cost_text : String = ""
    property activity : String = ""

    # The slash-command autocomplete popup. `completions` is what the CLI
    # offers (built-ins plus skills); the palette is the popup's live state.
    @completions : Array(Completion) = Array(Completion).new
    @palette : CommandPalette? = nil
    @popup_open : Bool = false

    getter? popup_open : Bool

    @on_submit : Proc(String, Nil)? = nil

    # Two seconds, not the library's default: a turn can take a moment to
    # notice the first interrupt, and a hasty second press should not kill it.
    INTERRUPT_WINDOW = 2.seconds
    @interrupts = 0
    @last_interrupt = Time.instant

    def initialize(@anvil : Anvil::App)
      @anvil.prompt = [Span.new("> ", Style.new(fg: Palette::USER, bold: true))]
      @anvil.status = ->(width : Int32) { status_line(width) }
      @anvil.hidden_marker = ->(hidden : Int32) { hidden_marker(hidden) }
      @anvil.popup = ->(width : Int32) { popup_lines(width) }
      @anvil.on_key = ->(event : Termisu::Event::Key) { intercept(event) }
      # The screen reflows under the live region: the rows an in-place redraw
      # would walk back over are no longer the rows it drew, so only a redraw
      # from scratch is sound afterwards — screen wiped, transcript re-emitted.
      @anvil.on_resize = -> { @anvil.redraw_all!; nil }
    end

    # The real thing: a live region at the bottom of the terminal.
    def self.terminal(history : Array(String) = Array(String).new) : App
      backend = Anvil::Backend.new(alternate_screen: false)
      surface = Anvil::Surface::Inline.new(backend, height: 1)
      # 30 fps is a ceiling, not a rate: a frame is drawn only when something
      # changed, so an idle prompt costs nothing.
      new(Anvil::App.new(surface, Anvil::Loop.for(backend, target_fps: 30), history: history))
    end

    delegate editor, blocks, state, mark_dirty, quit, surface, render, to: @anvil

    # Where the app's output goes — an `IO::Memory` under test.
    def io : IO
      surface.as(Anvil::Surface::Inline).io
    end

    # --- content -------------------------------------------------------------

    # `finalize` is kept for the callers that used it; a block reaches the
    # scrollback once it reports itself finalized, which is what the flag
    # always meant.
    def add_block(block : Anvil::View::Block, finalize : Bool = false) : Anvil::View::Block
      @anvil.add_block(block)
    end

    # smith's own notice block, not the library's generic one: it brings the
    # rendering the renderer relies on.
    def notice(text : String, style : Style = Style.new(fg: Palette::INFO)) : Nil
      add_block(NoticeBlock.text(text, style))
    end

    def notice(lines : Array(StyledLine)) : Nil
      add_block(NoticeBlock.new(lines))
    end

    def clear! : Nil
      @anvil.clear!
    end

    # A seam the renderer still calls: committing finished blocks is part of
    # drawing now, so this only has to ask for a frame.
    def flush_blocks! : Nil
      mark_dirty
    end

    def completions=(list : Array(Completion)) : Nil
      @completions = list
      @palette = nil
    end

    def on_interrupt(&block : -> Nil)
      @anvil.on_interrupt = block
    end

    def on_abort(&block : -> Nil)
      @anvil.on_abort = block
    end

    # Called by the turn fiber once agent.send returns, so the prompt comes
    # back.
    def turn_finished : Nil
      @activity = ""
      @interrupts = 0
      @anvil.idle!
    end

    def teardown : Nil
      surface.close
    end

    # --- modals --------------------------------------------------------------

    def modal(title : String, body : Array(StyledLine), choices : Array({Char, String}),
              chars : Array(Char)) : Char
      @anvil.ask(modal_header(title), body, chars, prompt_hint(choices), cancel: '\e')
    end

    def modal_text(title : String, body : Array(StyledLine)) : String
      @anvil.ask_text(modal_header(title), body)
    end

    # The same as `modal`, but driven by its own key loop — for decisions
    # needed before the main loop starts (the hooks trust prompt).
    def modal_sync(title : String, body : Array(StyledLine), choices : Array({Char, String}),
                   chars : Array(Char)) : Char
      @anvil.ask_sync(modal_header(title), body, chars, prompt_hint(choices), cancel: '\e')
    end

    private def hidden_marker(hidden : Int32) : StyledLine
      [Span.new("⋮ #{hidden} more line#{hidden == 1 ? "" : "s"} above",
        Style.new(fg: Palette::BORDER, dim: true))]
    end

    private def modal_header(title : String) : StyledLine
      [Span.new("▌ ", Style.new(fg: Palette::WARN)),
       Span.new(title, Style.new(bold: true))]
    end

    private def prompt_hint(choices : Array({Char, String})) : StyledLine
      line = StyledLine.new
      choices.each_with_index do |choice, i|
        char, label = choice
        line << Span.new("  ") if i > 0
        line << Span.new("[#{char}]", Style.new(fg: Palette::ACCENT, bold: true))
        line << Span.new(" #{label}", Style.new(fg: Palette::INFO))
      end
      line << Span.new("  [esc] cancel", Style.new(fg: Palette::BORDER))
      line
    end

    # --- the loop ------------------------------------------------------------

    def run(&on_submit : String -> Nil) : Nil
      @on_submit = on_submit
      # Submission runs through the key interceptor below, so the library's
      # own handler stays unused.
      @anvil.run { }
    end

    # Every key passes here before the library's state machine. Returning
    # true keeps it: an open popup owns the arrows, a running turn owns
    # Escape, and Ctrl-C means "clear what I typed" before it means "quit".
    private def intercept(event : Termisu::Event::Key) : Bool
      # Ctrl-L always belongs to the library: a garbled screen is likeliest
      # mid-turn or under a modal, which are exactly the states that would
      # otherwise swallow it.
      return false if event.ctrl? && event.key.to_char == 'l'

      case state
      when State::Idle then idle_key(event)
      when State::Busy then turn_key(event)
      else                  false
      end
    end

    private def idle_key(event : Termisu::Event::Key) : Bool
      key = event.key

      if event.ctrl?
        case key.to_char
        when 'c'
          if editor.empty?
            quit
          else
            close_popup
            editor.reset
          end
          return true
        when 'd'
          quit if editor.empty?
          return true
        end
        return false
      end

      case key
      when .escape?
        # The popup owns the first Escape: dismissing it is not clearing
        # what was typed. The next one clears the editor, as before.
        if popup_open?
          close_popup
        else
          editor.reset unless editor.empty?
        end
        true
      when .up?, .down?
        # The popup, while it is up, owns the arrow keys: selecting a
        # command is not walking the history.
        if popup_open? && (palette = @palette)
          key.up? ? palette.move_up : palette.move_down
          true
        else
          false
        end
      when .enter?
        submit(event)
        true
      when .tab?
        if popup_open?
          complete_from_popup
          true
        else
          false
        end
      else
        # Ordinary typing goes to the editor, and the popup follows it.
        editor.handle(event)
        refresh_popup
        true
      end
    end

    private def submit(event : Termisu::Event::Key) : Nil
      if current = popup_selection
        if current.takes_args
          # Complete the command word, then let the human type the
          # argument — submitting a half-typed `/resume` does nothing.
          editor.set_text("#{current.name} ")
          refresh_popup
          return
        end
        editor.set_text(current.name)
      end

      # Through the editor, not beside it: submitting is what files the
      # prompt into the history that Up and Down walk.
      text = editor.handle(event) || ""
      close_popup
      return if text.strip.empty?

      add_block(UserBlock.new(text))
      @anvil.busy!
      @interrupts = 0
      @on_submit.try &.call(text)
    end

    # While a turn runs the only keys that mean anything are the two ways of
    # asking it to stop.
    private def turn_key(event : Termisu::Event::Key) : Bool
      pressed = event.key.escape? || event.ctrl_c?
      return true unless pressed

      now = Time.instant
      @interrupts = 0 if now - @last_interrupt > INTERRUPT_WINDOW
      @last_interrupt = now
      @interrupts += 1

      if @interrupts == 1
        @anvil.on_interrupt.try &.call
        @activity = "stopping… (again to exit)"
      else
        @anvil.on_abort.try &.call
      end
      true
    end

    # --- popup ---------------------------------------------------------------

    def popup_matches : Array(Completion)
      @palette.try(&.matches) || Array(Completion).new
    end

    def popup_current : Completion?
      popup_open? ? @palette.try(&.current) : nil
    end

    # A stale palette from a previous popup must not decide an Enter.
    private def popup_selection : Completion?
      popup_open? ? @palette.try(&.current) : nil
    end

    private def refresh_popup : Nil
      query = CommandPalette.query_for(editor.text)
      if query.nil?
        close_popup
        return
      end

      palette = @palette ||= CommandPalette.new(@completions)
      palette.update(query)
      @popup_open = palette.open?
    end

    private def complete_from_popup : Nil
      return unless current = popup_selection

      editor.set_text(current.takes_args ? "#{current.name} " : current.name)
      refresh_popup
    end

    private def close_popup : Nil
      @popup_open = false
    end

    private def popup_lines(width : Int32) : Array(StyledLine)
      palette = @palette
      return Array(StyledLine).new unless popup_open? && palette

      selected_index = palette.selected
      top = palette.top

      palette.visible.map_with_index do |completion, i|
        index = top + i
        style = index == selected_index ? Style.new(reverse: true) : Style.new(dim: true)
        marker = index == selected_index ? "❯" : " "

        line = StyledLine.new
        line << Span.new("#{marker} ", Style.new(fg: Palette::ACCENT))
        line << Span.new(completion.name, Style.new(bold: true).merge(style))
        line << Span.new(" · ", Style.new(fg: Palette::BORDER))
        line << Span.new(completion.description, Style.new(dim: true).merge(style))

        LineUtil.truncate(line, width)
      end
    end

    # --- status bar ----------------------------------------------------------

    private def status_line(width : Int32) : StyledLine
      dim = Style.new(fg: Palette::INFO, dim: true)
      sep = Span.new(" · ", Style.new(fg: Palette::BORDER))

      parts = StyledLine.new

      parts << if state.idle?
        Span.new("⚒ ", Style.new(fg: Palette::WARN))
      else
        Span.new("#{Spinner.frame} ", Style.new(fg: Palette::ACCENT))
      end

      unless @model_name.empty?
        parts << Span.new(@model_name, dim)
        parts << sep
      end

      parts << case @mode
      in Smith::Mode::Plan
        Span.new("plan mode", Style.new(fg: Palette::MODE_PLAN, bold: true))
      in Smith::Mode::Normal
        Span.new("normal", dim)
      end

      unless @usage_text.empty?
        parts << sep
        parts << Span.new(@usage_text, dim)
      end
      unless @cost_text.empty?
        parts << sep
        parts << Span.new(@cost_text, dim)
      end

      unless @activity.empty?
        parts << sep
        parts << Span.new(@activity, Style.new(fg: Palette::WARN))
      end

      # Right-aligned key hint.
      hint = if state.idle?
               "enter send · ^c quit"
             elsif state.busy?
               "esc stop"
             else
               ""
             end

      used = LineUtil.width(parts)
      hint_width = LineUtil.width(hint)
      if !hint.empty? && used + hint_width + 4 <= width
        parts << Span.new(" " * (width - used - hint_width))
        parts << Span.new(hint, Style.new(fg: Palette::BORDER))
      end

      LineUtil.truncate(parts, width)
    end
  end
end
