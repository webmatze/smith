require "./terminal"
require "./style"
require "./view_model"
require "./input_editor"
require "../todos"
require "../mode"
require "../plan"

module Smith::UI
  # The fullscreen controller. Owns the terminal, the block list and the key
  # loop; everything else — the renderer, the approver, the plan gate — asks
  # it to show things and, where a human decision is needed, blocks until one
  # arrives.
  #
  # Rendering model (same as Claude Code): finished blocks are flushed into
  # the normal scrollback once; the live region at the bottom — streaming
  # text, running tools, status bar, input — is redrawn in place every tick.
  # No alternate screen, so the transcript stays in the terminal's scrollback
  # and can be copied and searched like any other output.
  class App
    enum State
      Idle      # at the prompt: the editor takes the keys
      Turn      # the agent is running
      ModalChar # waiting for one of a set of keys
      ModalText # waiting for a line of text (plan feedback)
      Done
    end

    getter terminal : Terminal
    getter editor : InputEditor
    getter blocks : Array(Block)
    getter state : State

    @flushed = 0
    @printed = 0
    @drawn_height = 0
    @dirty = true
    @running = false
    @interrupts = 0
    @last_interrupt = Time.instant

    @char_channel : Channel(Char)? = nil
    @text_channel : Channel(String)? = nil
    @modal_chars : Array(Char) = [] of Char
    @modal_title : String = ""
    @modal_blocks : Array(Block) = [] of Block
    @modal_prompt : StyledLine = LineUtil::EMPTY

    @on_interrupt : Proc(Nil)? = nil
    @on_abort : Proc(Nil)? = nil

    # Status bar contents, updated by whoever drives the run.
    property model_name : String = ""
    property mode : Smith::Mode = Smith::Mode::Normal
    property usage_text : String = ""
    property cost_text : String = ""
    property activity : String = ""

    def initialize(@terminal : Terminal = Terminal.new, history : Array(String) = Array(String).new)
      @editor = InputEditor.new(history)
      @blocks = Array(Block).new
      @state = State::Idle
    end

    def on_interrupt(&block : -> Nil)
      @on_interrupt = block
    end

    # Called on the second interrupt within two seconds.
    def on_abort(&block : -> Nil)
      @on_abort = block
    end

    # --- block intake -------------------------------------------------------

    def add_block(block : Block, finalize : Bool = false) : Block
      @blocks << block
      @dirty = true
      flush_blocks! if finalize
      block
    end

    def notice(text : String, style : Style = Style.new(fg: Palette::INFO)) : Nil
      add_block(NoticeBlock.text(text, style), finalize: true)
    end

    def notice(lines : Array(StyledLine)) : Nil
      add_block(NoticeBlock.new(lines), finalize: true)
    end

    # Every finished block, in order, moves into the scrollback — printed once
    # by draw! and never redrawn after that.
    def flush_blocks! : Nil
      while @flushed < @blocks.size
        break unless @blocks[@flushed].finalized?
        @flushed += 1
        @dirty = true
      end
    end

    def mark_dirty : Nil
      @dirty = true
    end

    # --- modals ---------------------------------------------------------------

    # Blocks until the user presses one of `chars` (Escape always answers too,
    # as a cancel). Called from the turn fiber while the main loop is running.
    def modal(title : String, body : Array(StyledLine), choices : Array({Char, String}), chars : Array(Char)) : Char
      channel = Channel(Char).new(1)
      @char_channel = channel
      @modal_chars = chars
      set_modal(title, body)
      @modal_prompt = [Span.new(prompt_hint(choices), Style.new(fg: Palette::ACCENT))]
      @state = State::ModalChar
      @dirty = true

      answer = channel.receive
      @char_channel = nil
      clear_modal
      @modal_prompt = LineUtil::EMPTY
      @state = State::Turn
      @dirty = true
      answer
    end

    # Blocks until the user submits a line of text (plan feedback).
    def modal_text(title : String, body : Array(StyledLine)) : String
      channel = Channel(String).new(1)
      @text_channel = channel
      set_modal(title, body)
      # ASCII for the same cursor-math reason as the idle prompt.
      @modal_prompt = [Span.new("> ", Style.new(fg: Palette::ACCENT, bold: true))]
      @state = State::ModalText
      @editor.reset
      @dirty = true

      answer = channel.receive
      @text_channel = nil
      clear_modal
      @modal_prompt = LineUtil::EMPTY
      @state = State::Turn
      @dirty = true
      answer
    end

    # The same as `modal`, but driven by its own key loop — for decisions
    # needed before the main loop starts (the hooks trust prompt).
    def modal_sync(title : String, body : Array(StyledLine), choices : Array({Char, String}), chars : Array(Char)) : Char
      @terminal.enter! unless @terminal.raw?
      @terminal.hide_cursor

      saved_title = @modal_title
      saved_blocks = @modal_blocks
      saved_prompt = @modal_prompt
      saved_state = @state
      set_modal(title, body)
      @modal_prompt = [Span.new(prompt_hint(choices), Style.new(fg: Palette::ACCENT))]
      @state = State::ModalChar
      draw!

      answer = '\e'
      loop do
        key = @terminal.read_key

        # Its own loop, so it needs its own ^L — the main loop's never sees a
        # key while this one is up.
        if key.kind.ctrl? && key.char == 'l'
          redraw_all!
          draw!
          next
        end

        char = key_to_answer(key, chars)
        next if char.nil?

        answer = char
        break
      end

      @modal_title = saved_title
      @modal_blocks = saved_blocks
      @modal_prompt = saved_prompt
      @state = saved_state

      clear_drawn!
      @terminal.show_cursor
      answer
    end

    private def prompt_hint(choices : Array({Char, String})) : String
      choices.map { |(char, label)| "[#{char}] #{label}" }.join("  ")
    end

    # The title is kept apart from the body on purpose: the body is droppable
    # when the region outgrows the screen, the question above it is not.
    private def set_modal(title : String, body : Array(StyledLine)) : Nil
      @modal_title = title
      @modal_blocks = body.empty? ? [] of Block : [NoticeBlock.new(body)] of Block
    end

    private def clear_modal : Nil
      @modal_title = ""
      @modal_blocks = [] of Block
    end

    private def modal_open? : Bool
      !@modal_title.empty? || !@modal_blocks.empty?
    end

    private def modal_header_line : StyledLine
      header = StyledLine.new
      header << Span.new("┃ ", Style.new(fg: Palette::WARN, bold: true))
      header << Span.new(@modal_title, Style.new(bold: true))
      header
    end

    private def key_to_answer(key : Key, chars : Array(Char)) : Char?
      case key.kind
      in Key::Kind::Char
        ch = key.char.not_nil!
        chars.includes?(ch) ? ch : nil
      in Key::Kind::Escape, Key::Kind::Eof
        '\e'
      in Key::Kind::Ctrl
        key.char == 'c' ? '\e' : nil
      in Key::Kind::Paste, Key::Kind::Enter, Key::Kind::Newline, Key::Kind::Backspace,
         Key::Kind::Delete, Key::Kind::Left, Key::Kind::Right, Key::Kind::Up, Key::Kind::Down,
         Key::Kind::Home, Key::Kind::End, Key::Kind::Tick, Key::Kind::Resized, Key::Kind::Unknown
        nil
      end
    end

    # --- the main loop ----------------------------------------------------------

    def run(&on_submit : String -> Nil) : Nil
      @running = true
      @terminal.enter!
      @terminal.hide_cursor
      draw!

      begin
        loop do
          key = @terminal.read_key

          # Lets a freshly spawned turn or modal set up its state before this
          # key is interpreted against it. On a real terminal read_key yields
          # every tick anyway; this makes the ordering deterministic — and it
          # is also what lets a waiting fiber consume the answer that the key
          # below is about to deliver before the loop tears down on EOF.
          Fiber.yield

          # A closed terminal ends the session whatever it was doing — there is
          # nobody left to watch it anyway.
          break if key.kind.eof?

          # ^L redraws whatever the app is doing. Handled above the state
          # machine because a garbled screen is likeliest mid-turn or under a
          # modal — the two states that would otherwise swallow the key.
          if key.kind.ctrl? && key.char == 'l'
            redraw_all!
            flush_blocks!
            draw!
            next
          end

          case @state
          when State::Idle
            break if handle_idle_key(key, on_submit)
          when State::Turn
            handle_turn_key(key)
          when State::ModalChar
            if channel = @char_channel
              if answer = key_to_answer(key, @modal_chars)
                @state = State::Turn
                channel.send(answer)
              end
            end
          when State::ModalText
            if channel = @text_channel
              if key.kind.enter?
                text = @editor.text
                @editor.reset
                @state = State::Turn
                channel.send(text)
              else
                @editor.handle(key)
                @dirty = true
              end
            end
          when State::Done
            break
          end

          flush_blocks!
          draw! if needs_draw?
        end
      ensure
        teardown
      end
    end

    # Called by the turn fiber once agent.send returns, so the prompt comes
    # back.
    def turn_finished : Nil
      @state = State::Idle if @state.turn?
      @activity = ""
      flush_blocks!
      @dirty = true
    end

    def quit : Nil
      @state = State::Done
    end

    private def handle_idle_key(key : Key, on_submit : String -> Nil) : Bool
      case key.kind
      in Key::Kind::Escape
        @editor.reset unless @editor.empty?
      in Key::Kind::Eof
        return true
      in Key::Kind::Ctrl
        case key.char
        when 'c'
          return true if @editor.empty?
          @editor.reset
        when 'd'
          return true if @editor.empty?
        end
      in Key::Kind::Enter
        # Through the editor, not beside it: submitting is what files the
        # prompt into the history that Up and Down walk. The editor resets
        # itself either way, so a stray run of spaces does not linger.
        text = @editor.handle(key) || ""
        return false if text.strip.empty?

        add_block(UserBlock.new(text), finalize: true)
        @state = State::Turn
        @interrupts = 0
        on_submit.call(text)
      in Key::Kind::Char, Key::Kind::Paste, Key::Kind::Newline, Key::Kind::Backspace,
         Key::Kind::Delete, Key::Kind::Left, Key::Kind::Right, Key::Kind::Up, Key::Kind::Down,
         Key::Kind::Home, Key::Kind::End
        @editor.handle(key)
        @dirty = true
      in Key::Kind::Tick, Key::Kind::Resized, Key::Kind::Unknown
        # Nothing to do — resize is picked up by needs_draw? on its own.
      end
      false
    end

    # First interrupt asks the agent to stop; a second one within two seconds
    # aborts outright.
    private def handle_turn_key(key : Key) : Nil
      pressed = key.kind.escape? || (key.kind.ctrl? && key.char == 'c')
      return unless pressed

      now = Time.instant
      @interrupts = 0 if now - @last_interrupt > 2.seconds
      @last_interrupt = now
      @interrupts += 1

      if @interrupts == 1
        @on_interrupt.try &.call
        @activity = "stopping… (again to exit)"
        @dirty = true
      else
        @on_abort.try &.call
      end
    end

    private def needs_draw? : Bool
      return true if @dirty
      return true if @terminal.resized?

      # Spinners and elapsed times animate while anything is in flight.
      @state.turn? || @state.modal_char? || @state.modal_text?
    end

    # --- drawing ------------------------------------------------------------

    private def draw! : Nil
      width, height = @terminal.size
      @terminal.clear_resize! if @terminal.resized?

      # Take down the live region, print newly finished blocks into the
      # scrollback, then rebuild the live region below them.
      clear_drawn!

      if @printed < @flushed
        (@printed...@flushed).each do |i|
          print_block(@blocks[i], width)
        end
        @printed = @flushed
      end

      region = live_lines(width, height)
      region.each_with_index do |line, i|
        @terminal.write "\r"
        @terminal.clear_line
        # One region line must occupy exactly one terminal row: a line that
        # wraps would put clear_drawn! out of step with the screen and leave
        # the previous frame behind.
        @terminal.write_line(LineUtil.truncate(line, width))
        @terminal.newline if i < region.size - 1
      end

      @drawn_height = region.size
      place_cursor(width)
      @dirty = false
    end

    private def print_block(block : Block, width : Int32) : Nil
      block.lines(width).each do |line|
        @terminal.write_line(line)
        @terminal.newline
      end
      @terminal.newline
    end

    # One horizontal slice of the live region. A droppable slice gives up its
    # oldest lines when the region outgrows the screen; a pinned one — the
    # modal's question, its choices, the status bar, the prompt — never does.
    private record Segment, lines : Array(StyledLine), pinned : Bool

    private def live_lines(width : Int32, height : Int32 = Terminal::DEFAULT_HEIGHT) : Array(StyledLine)
      segments = Array(Segment).new

      # Blocks still in flight.
      if @flushed < @blocks.size
        lines = Array(StyledLine).new
        (@flushed...@blocks.size).each_with_index do |i, n|
          lines << LineUtil::EMPTY if n > 0
          lines.concat(@blocks[i].lines(width))
        end
        lines << LineUtil::EMPTY if modal_open?
        segments << Segment.new(lines, false)
      end

      # The modal region, when one is up: the question stays, the body it
      # describes is what gives way.
      if modal_open?
        segments << Segment.new([modal_header_line], true)

        body = Array(StyledLine).new
        @modal_blocks.each_with_index do |block, i|
          body << LineUtil::EMPTY if i > 0
          body.concat(block.lines(width))
        end
        segments << Segment.new(body, false) unless body.empty?

        unless @modal_prompt.empty?
          # The blank above is a separator, not content: on a screen too small
          # for everything it goes before the line it separates.
          segments << Segment.new([LineUtil::EMPTY], false)
          segments << Segment.new([@modal_prompt + modal_editor_line(width)], true)
        end
      end

      segments << Segment.new([LineUtil::EMPTY], false) unless segments.empty?

      tail = Array(StyledLine).new
      tail << status_line(width)
      # A turn in flight shows nothing under the status bar, and in ModalText
      # the prompt line above already carries the editor.
      tail << input_line(width) if @state.idle?
      segments << Segment.new(tail, true)

      clamp_height(segments, height)
    end

    # The live region is redrawn in place, and that only works while it fits
    # on the screen: cursor_up stops at the top row, so a taller region can
    # never be walked back over — every redraw would push another copy of it
    # into the scrollback (an approval modal on top of a running tool is the
    # usual way to get there). Droppable lines give way instead, oldest first,
    # behind a marker saying how many went.
    private def clamp_height(segments : Array(Segment), height : Int32) : Array(StyledLine)
      budget = height - 1
      budget = 1 if budget < 1

      total = segments.sum { |segment| segment.lines.size }
      return segments.flat_map(&.lines) if total <= budget

      # The marker costs a line of its own, so it comes out of the room the
      # pinned lines leave behind.
      pinned = segments.sum { |segment| segment.pinned ? segment.lines.size : 0 }
      room = budget - pinned - 1
      room = 0 if room < 0

      hidden = (total - pinned) - room
      remaining = hidden
      marked = false
      region = Array(StyledLine).new

      segments.each do |segment|
        if segment.pinned || remaining <= 0
          region.concat(segment.lines)
          next
        end

        dropped = {remaining, segment.lines.size}.min
        remaining -= dropped
        # One marker, standing where the first dropped line was.
        unless marked
          region << hidden_marker(hidden)
          marked = true
        end
        region.concat(segment.lines[dropped..])
      end

      return region if region.size <= budget

      # A screen too small to hold even the pinned lines. The bottom is what
      # survives — the keys, the status bar — but the question keeps its row
      # ahead of them: keys answering an unnamed request are worth less than
      # the request. The marker goes with everything else that is cut, so no
      # count is left behind claiming to be exact.
      head = modal_open? ? [modal_header_line] : Array(StyledLine).new
      head = Array(StyledLine).new if head.size >= budget
      keep = budget - head.size
      head + region[(region.size - keep)..]
    end

    private def hidden_marker(hidden : Int32) : StyledLine
      [Span.new("⋮ #{hidden} more line#{hidden == 1 ? "" : "s"} above", Style.new(fg: Palette::BORDER, dim: true))]
    end

    private def modal_editor_line(width : Int32) : StyledLine
      return LineUtil::EMPTY unless @state.modal_text?
      editor_spans(width)
    end

    private def input_line(width : Int32) : StyledLine
      # ASCII prompt on purpose: its width is 2 in every terminal, so the
      # cursor math below it can never drift.
      [Span.new("> ", Style.new(fg: Palette::USER, bold: true))] + editor_spans(width)
    end

    # Horizontal scroll once the text outgrows the line. The scroll amount
    # comes from the same helper place_cursor uses, so the visible window and
    # the cursor can never disagree.
    private def editor_spans(width : Int32) : StyledLine
      available = width - 2
      available = 1 if available < 1

      scroll = scroll_offset(width)
      [Span.new(slice_columns(@editor.text, scroll, available))]
    end

    # Cuts a string to a column window without splitting wide characters.
    private def slice_columns(text : String, from : Int32, length : Int32) : String
      String.build do |io|
        col = 0
        text.each_char do |ch|
          w = Style.char_width(ch)
          io << ch if col + w > from && col < from + length
          col += w
          break if col >= from + length
        end
      end
    end

    private def status_line(width : Int32) : StyledLine
      dim = Style.new(fg: Palette::INFO, dim: true)
      sep = Span.new(" · ", Style.new(fg: Palette::BORDER))

      parts = StyledLine.new

      busy = @state.turn? || @state.modal_char? || @state.modal_text?
      parts << if busy
        Span.new("#{Spinner.frame} ", Style.new(fg: Palette::ACCENT))
      else
        Span.new("⚒ ", Style.new(fg: Palette::WARN))
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
      hint = case @state
             when State::Idle
               "enter send · ^c quit"
             when State::Turn
               "esc stop"
             else
               ""
             end

      used = LineUtil.width(parts)
      hint_width = Style.display_width(hint)
      if !hint.empty? && used + hint_width + 4 <= width
        parts << Span.new(" " * (width - used - hint_width))
        parts << Span.new(hint, Style.new(fg: Palette::BORDER))
      end

      LineUtil.truncate(parts, width)
    end

    private def place_cursor(width : Int32) : Nil
      case @state
      when State::Idle, State::ModalText
        @terminal.show_cursor
        # The prompt prefix is "> " in both places — two columns.
        @terminal.cursor_to_column(2 + @editor.columns_before_cursor - scroll_offset(width) + 1)
      else
        @terminal.hide_cursor
      end
    end

    # How far the editor view has scrolled right once the text outgrows the
    # line. Shared with place_cursor so the cursor can never drift from the
    # text it sits in.
    private def scroll_offset(width : Int32) : Int32
      available = width - 2
      available = 1 if available < 1

      text_col = @editor.columns_before_cursor
      scroll = 0
      scroll = text_col - (available - 1) if text_col > available - 1

      max_scroll = @editor.display_width - available
      scroll = max_scroll if scroll > max_scroll
      scroll < 0 ? 0 : scroll
    end

    # The cursor sits on the region's last line after every draw!; this takes
    # the whole region down and parks the cursor where it started.
    private def clear_drawn! : Nil
      height = @drawn_height
      return if height.zero?

      @terminal.cursor_up(height - 1)
      height.times do |i|
        @terminal.write "\r"
        @terminal.clear_line
        @terminal.newline if i < height - 1
      end
      @terminal.cursor_up(height - 1) if height > 1
      @drawn_height = 0
    end

    # ^L: wipe the screen and re-emit the scrollback from scratch.
    private def redraw_all! : Nil
      @terminal.write "\e[2J\e[H"
      @printed = 0
      @drawn_height = 0
      @dirty = true
    end

    # --- exit ------------------------------------------------------------------

    def teardown : Nil
      clear_drawn! if @running
      @terminal.leave!
      @running = false
    end
  end
end
