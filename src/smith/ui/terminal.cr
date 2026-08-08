module Smith::UI
  # One parsed key press.
  struct Key
    enum Kind
      Char # a printable character (in #char)
      Ctrl # Ctrl+letter (in #char, lowercase)
      Enter
      Newline # Ctrl+J / bare LF — inserts a line break in the editor
      Backspace
      Delete
      Left
      Right
      Up
      Down
      Home
      End
      Escape
      Paste   # bracketed paste payload (in #text)
      Tick    # no input within the poll window; redraw if needed
      Resized # SIGWINCH was observed
      Eof     # stdin closed
      Unknown
    end

    getter kind : Kind
    getter char : Char?
    getter text : String?

    private def initialize(@kind : Kind, @char : Char? = nil, @text : String? = nil)
    end

    def self.char(c : Char) : Key
      new(Kind::Char, char: c)
    end

    def self.ctrl(c : Char) : Key
      new(Kind::Ctrl, char: c)
    end

    def self.paste(text : String) : Key
      new(Kind::Paste, text: text)
    end

    {% for name in %w[Enter Newline Backspace Delete Left Right Up Down Home End Escape Tick Resized Eof Unknown] %}
      def self.{{name.id.underscore}} : Key
        new(Kind::{{name.id}})
      end
    {% end %}
  end

  # Parses a byte stream into Keys. Split out from Terminal so specs can drive
  # it with an IO::Memory.
  module KeyParser
    # Reads one key from the given IO. Returns nil when the IO has no more
    # data right now (timeout on a real terminal, EOF on a memory buffer) —
    # the caller decides what that means.
    def self.parse(io : IO) : Key?
      first = io.read_byte
      return nil if first.nil?

      case first
      when 0x0D       then return Key.enter
      when 0x0A       then return Key.newline
      when 0x7F, 0x08 then return Key.backspace
      when 0x09       then return Key.char('\t')
      when 0x00       then return Key.ctrl(' ')
      when 0x01..0x1A then return Key.ctrl(('a'.ord + first - 1).unsafe_chr)
      when 0x1B       then parse_escape(io)
      else
        parse_utf8(first, io).try { |c| Key.char(c) } || Key.unknown
      end
    end

    # ESC either starts a sequence or is a key of its own; the only way to
    # tell is whether more bytes follow almost immediately. When nothing
    # follows — EOF in a buffer, or the read window expiring on a live
    # terminal — the ESC was the keypress itself.
    private def self.parse_escape(io : IO) : Key
      second = begin
        io.read_byte
      rescue IO::TimeoutError
        nil
      end
      return Key.escape if second.nil?

      case second
      when 0x5B # CSI: ESC [
        parse_csi(io)
      when 0x4F # SS3: ESC O (arrows on some terminals' application mode)
        final = io.read_byte
        case final
        when 0x41 then Key.up
        when 0x42 then Key.down
        when 0x43 then Key.right
        when 0x44 then Key.left
        when 0x48 then Key.home
        when 0x46 then Key.end
        else           Key.unknown
        end
      when 0x0D then Key.newline # Alt+Enter, sent by many terminals
      when 0x0A then Key.newline
      else
        # Alt+<char>: the combination arrives as ESC plus a letter, and the
        # letter is already consumed here. Reporting the Escape is the honest
        # answer; nothing meaningful is lost for smith's keys.
        Key.escape
      end
    end

    private def self.parse_csi(io : IO) : Key
      params = String::Builder.new

      loop do
        b = io.read_byte
        return Key.unknown if b.nil?

        case b
        when 0x30..0x3F, 0x20..0x2F # parameter and intermediate bytes
          params << b.unsafe_chr
        when 0x40..0x7E # final byte
          final = b.unsafe_chr
          return finish_csi(params.to_s, final, io)
        else
          return Key.unknown
        end
      end
    end

    private def self.finish_csi(params : String, final : Char, io : IO) : Key
      case final
      when 'A' then Key.up
      when 'B' then Key.down
      when 'C' then Key.right
      when 'D' then Key.left
      when 'H' then Key.home
      when 'F' then Key.end
      when '~'
        case params.to_i?
        when 1, 7 then Key.home
        when 3    then Key.delete
        when 4, 8 then Key.end
        when 200  then read_paste(io)
        else           Key.unknown
        end
      else
        Key.unknown
      end
    end

    # Bracketed paste: everything until ESC [ 201 ~ is payload, verbatim.
    private def self.read_paste(io : IO) : Key
      payload = String::Builder.new
      state = 0 # 0: normal, 1: seen ESC, 2: seen ESC[, then match "201~"
      matched = ""

      loop do
        b = io.read_byte
        break if b.nil?
        c = b.unsafe_chr

        case state
        when 0
          if c == '\e'
            state = 1
          else
            payload << c
          end
        when 1
          if c == '['
            state = 2
            matched = ""
          else
            payload << '\e' << c
            state = 0
          end
        when 2
          matched += c
          if "201~".starts_with?(matched)
            return Key.paste(payload.to_s) if matched == "201~"
          else
            payload << '\e' << '[' << matched
            state = 0
            matched = ""
          end
        end
      end

      Key.paste(payload.to_s)
    end

    private def self.parse_utf8(first : UInt8, io : IO) : Char?
      # Fast path: plain ASCII.
      return first.unsafe_chr if first < 0x80

      length = if first >= 0xF0
                 4
               elsif first >= 0xE0
                 3
               elsif first >= 0xC0
                 2
               else
                 return nil
               end

      bytes = Bytes.new(length)
      bytes[0] = first
      (1...length).each do |i|
        b = io.read_byte
        return nil if b.nil?
        bytes[i] = b
      end

      String.new(bytes).each_char.first?
    rescue
      nil
    end
  end

  lib LibTUI
    struct Winsize
      ws_row : UInt16
      ws_col : UInt16
      ws_xpixel : UInt16
      ws_ypixel : UInt16
    end

    fun ioctl(fd : Int32, request : UInt64, ...) : Int32
  end

  # Terminal size query and raw-mode handling. Wraps the few ioctls and
  # termios calls the UI needs, so everything else deals in plain methods.
  class Terminal
    TIOCGWINSZ = {% if flag?(:darwin) || flag?(:bsd) %}
                   0x40087468_u64
                 {% elsif flag?(:linux) %}
                   0x5413_u64
                 {% else %}
                   0_u64
                 {% end %}

    DEFAULT_WIDTH  = 80
    DEFAULT_HEIGHT = 24

    getter io : IO
    getter? color : Bool

    def initialize(@io : IO = STDOUT, @input : IO = STDIN, @color : Bool = true, @width : Int32? = nil, @height : Int32? = nil)
      @raw = false
      @original_termios = LibC::Termios.new
      @winch = false
    end

    # --- size -------------------------------------------------------------

    def width : Int32
      size[0]
    end

    def height : Int32
      size[1]
    end

    def size : {Int32, Int32}
      return {@width.not_nil!, @height.not_nil!} if @width && @height

      ws = LibTUI::Winsize.new
      if TIOCGWINSZ != 0 && LibTUI.ioctl(0, TIOCGWINSZ, pointerof(ws)) == 0 && ws.ws_col > 0
        {ws.ws_col.to_i, ws.ws_row.to_i}
      else
        w = ENV.fetch("COLUMNS", nil).try(&.to_i?) || DEFAULT_WIDTH
        h = ENV.fetch("LINES", nil).try(&.to_i?) || DEFAULT_HEIGHT
        {w, h}
      end
    end

    def resized? : Bool
      @winch
    end

    def clear_resize! : Nil
      @winch = false
    end

    def install_winch_handler : Nil
      Signal::WINCH.trap { mark_resized! }
    end

    # The window changed size. Set from the SIGWINCH handler above; specs
    # drive it directly, having no window to drag.
    def mark_resized! : Nil
      @winch = true
    end

    # --- raw mode ----------------------------------------------------------

    def enter! : Nil
      return if @raw
      # Raw mode only makes sense on a real terminal. An IO::Memory input —
      # the specs — must never touch the developer's actual terminal.
      return unless @input.is_a?(IO::FileDescriptor)

      fd = 0
      orig = uninitialized LibC::Termios
      return if LibC.tcgetattr(fd, pointerof(orig)) != 0

      raw = orig
      # No line buffering, no echo, no signal generation (Ctrl+C becomes a
      # byte the app owns), no CR->NL input mapping so Enter ('\r') and
      # Ctrl+J ('\n') stay distinguishable.
      raw.c_lflag &= ~(LibC::ECHO | LibC::ICANON | LibC::ISIG | LibC::IEXTEN)
      raw.c_iflag &= ~(LibC::IXON | LibC::ICRNL)

      return if LibC.tcsetattr(fd, LibC::TCSANOW, pointerof(raw)) != 0

      @original_termios = orig
      @raw = true

      # Whatever way the process ends, the terminal must not be left raw.
      at_exit { leave! }

      write "\e[?2004h" # bracketed paste
      install_winch_handler
    end

    def leave! : Nil
      write "\e[?2004l" if @raw
      if @raw
        LibC.tcsetattr(0, LibC::TCSAFLUSH, pointerof(@original_termios))
        @raw = false
      end
      show_cursor
    end

    def raw? : Bool
      @raw
    end

    # --- keys ----------------------------------------------------------------

    # Reads a key, waiting at most `timeout`. Returns Tick when nothing
    # arrived in that window, Resized when the window changed, Eof when the
    # input is gone for good.
    def read_key(timeout : Time::Span = 50.milliseconds) : Key
      return Key.resized if @winch

      input = @input
      if input.responds_to?(:read_timeout=)
        input.read_timeout = timeout
      end

      result = begin
        KeyParser.parse(input) || :eof
      rescue IO::TimeoutError
        :timeout
      end

      case result
      when Key
        result
      when Symbol
        result == :eof ? Key.eof : (@winch ? Key.resized : Key.tick)
      else
        raise "unreachable"
      end
    end

    # --- output helpers -------------------------------------------------------

    def write(text : String) : Nil
      @io.print text
      @io.flush
    end

    def write_line(line : StyledLine) : Nil
      LineUtil.render(line, @io, @color)
      @io.flush
    end

    def newline : Nil
      write "\r\n"
    end

    def cursor_up(n : Int32) : Nil
      write "\e[#{n}A" if n > 0
    end

    def cursor_to_column(n : Int32) : Nil
      write "\e[#{n}G"
    end

    def clear_line : Nil
      write "\e[2K"
    end

    def hide_cursor : Nil
      write "\e[?25l"
    end

    def show_cursor : Nil
      write "\e[?25h"
    end
  end
end
