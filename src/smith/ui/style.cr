module Smith::UI
  # The smallest unit of styled terminal text. Styles are merged while a line
  # is assembled, so markdown rendering can layer emphasis on top of a block's
  # base style without knowing about it.
  struct Style
    # 256-colour palette index; nil keeps the terminal default.
    property fg : Int32?
    property? bold : Bool
    property? dim : Bool
    property? italic : Bool
    property? underline : Bool
    property? invert : Bool

    def initialize(@fg : Int32? = nil, @bold : Bool = false, @dim : Bool = false,
                   @italic : Bool = false, @underline : Bool = false, @invert : Bool = false)
    end

    NONE = Style.new

    def plain? : Bool
      fg.nil? && !bold? && !dim? && !italic? && !underline? && !invert?
    end

    # `other` wins wherever it is set; used to layer inline markdown styles on
    # top of the block style they appear in.
    def merge(other : Style) : Style
      Style.new(
        fg: other.fg || @fg,
        bold: other.bold? || @bold,
        dim: other.dim? || @dim,
        italic: other.italic? || @italic,
        underline: other.underline? || @underline,
        invert: other.invert? || @invert
      )
    end

    def ansi : String
      return "" if plain?

      String.build do |io|
        io << "\e["
        parts = [] of String
        parts << "1" if bold?
        parts << "2" if dim?
        parts << "3" if italic?
        parts << "4" if underline?
        parts << "7" if invert?
        if f = fg
          parts << "38;5;#{f}"
        end
        io << parts.join(";")
        io << "m"
      end
    end

    # --- display width -------------------------------------------------

    # Columns a string occupies in the terminal. ASCII is 1; CJK, fullwidth
    # forms and most emoji are 2; combining marks and zero-width characters
    # are 0. An approximation — but the same one most terminals make.
    def self.display_width(text : String) : Int32
      total = 0
      text.each_char { |c| total += char_width(c) }
      total
    end

    def self.char_width(char : Char) : Int32
      cp = char.ord
      return 0 if cp == 0
      return 0 if zero_width?(cp)
      return 1 if cp < 0x1100
      wide?(cp) ? 2 : 1
    end

    private def self.zero_width?(cp : Int32) : Bool
      # Combining diacritics, format characters, variation selectors.
      (0x0300..0x036F).includes?(cp) ||
        (0x200B..0x200F).includes?(cp) ||
        cp == 0xFEFF ||
        (0xFE00..0xFE0F).includes?(cp) ||
        (0x1F3FB..0x1F3FF).includes?(cp) # emoji skin tone modifiers
    end

    private def self.wide?(cp : Int32) : Bool
      (0x1100..0x115F).includes?(cp) ||   # Hangul Jamo
        (0x2E80..0x303E).includes?(cp) || # CJK radicals .. CJK symbols
        (0x3041..0x33FF).includes?(cp) || # Kana, CJK compatibility
        (0x3400..0x4DBF).includes?(cp) ||
        (0x4E00..0x9FFF).includes?(cp) || # CJK unified
        (0xA000..0xA4CF).includes?(cp) ||
        (0xAC00..0xD7A3).includes?(cp) || # Hangul syllables
        (0xF900..0xFAFF).includes?(cp) ||
        (0xFE30..0xFE4F).includes?(cp) ||
        (0xFF00..0xFF60).includes?(cp) || # fullwidth forms
        (0xFFE0..0xFFE6).includes?(cp) ||
        (0x2600..0x27BF).includes?(cp) || # misc symbols / dingbats
        (0x2B00..0x2BFF).includes?(cp) ||
        (0x1F000..0x1FAFF).includes?(cp) # emoji & friends
    end
  end

  record Span, text : String, style : Style = Style::NONE do
    def width : Int32
      Style.display_width(text)
    end
  end

  alias StyledLine = Array(Span)

  # Line-level helpers shared by everything that lays text out.
  module LineUtil
    def self.width(line : StyledLine) : Int32
      line.sum(&.width)
    end

    def self.plain(line : StyledLine) : String
      line.map(&.text).join
    end

    # A styled line from plain text.
    def self.line(text : String, style : Style = Style::NONE) : StyledLine
      [Span.new(text, style)]
    end

    EMPTY = [] of Span

    # Greedy word wrap that keeps styles intact. Words longer than the width
    # are hard-broken; spaces at a wrap point are dropped rather than trailing.
    def self.wrap(line : StyledLine, width : Int32) : Array(StyledLine)
      width = 1 if width < 1

      out = Array(StyledLine).new
      current = Array({Char, Style}).new
      current_w = 0
      last_break = -1

      line.each do |span|
        style = span.style
        span.text.each_char do |ch|
          if ch == '\n'
            out << group(current)
            current = Array({Char, Style}).new
            current_w = 0
            last_break = -1
            next
          end

          w = Style.char_width(ch)

          if ch == ' '
            # A space that would wrap is dropped outright: keeping it would
            # leave a ragged right edge of invisible padding.
            if current_w + w <= width
              current << {ch, style}
              current_w += w
              last_break = current.size - 1
            end
            next
          end

          if current_w + w > width
            if last_break >= 0
              tail = current[(last_break + 1)..]
              current = current[0...last_break]
              out << group(current)
              current = tail
              current_w = tail.sum { |(c, _s)| Style.char_width(c) }
              last_break = -1
            else
              out << group(current)
              current = Array({Char, Style}).new
              current_w = 0
            end
          end

          current << {ch, style}
          current_w += w
        end
      end

      out << group(current)
      out
    end

    private def self.group(chars : Array({Char, Style})) : StyledLine
      spans = StyledLine.new
      chars.each do |(ch, style)|
        if last = spans.last?
          if last.style == style
            spans[-1] = Span.new(last.text + ch.to_s, style)
            next
          end
        end
        spans << Span.new(ch.to_s, style)
      end
      spans
    end

    # Cuts a line to `width` columns, optionally with an ellipsis. Never
    # splits a double-width character in half: if it does not fit, the cut
    # happens one column earlier.
    def self.truncate(line : StyledLine, width : Int32, ellipsis : String? = nil) : StyledLine
      return line if width(line) <= width

      ell = ellipsis ? line(ellipsis, Style.new(dim: true)) : EMPTY
      budget = width - (ellipsis ? Style.display_width(ellipsis.not_nil!) : 0)
      budget = 0 if budget < 0

      out = StyledLine.new
      used = 0
      line.each do |span|
        break if used >= budget
        kept = String.build do |io|
          span.text.each_char do |ch|
            w = Style.char_width(ch)
            break if used + w > budget
            io << ch
            used += w
          end
        end
        out << Span.new(kept, span.style) unless kept.empty?
      end
      out + ell
    end

    def self.pad(line : StyledLine, width : Int32) : StyledLine
      missing = width - width(line)
      return line if missing <= 0
      line + [Span.new(" " * missing)]
    end

    def self.to_ansi(line : StyledLine, color : Bool = true) : String
      String.build { |io| render(line, io, color) }
    end

    def self.render(line : StyledLine, io : IO, color : Bool = true) : Nil
      current = Style::NONE
      line.each do |span|
        style = span.style
        if color && style != current
          io << "\e[0m" unless current.plain?
          io << style.ansi
          current = style
        end
        io << span.text
      end
      # The final reset only makes sense when styles were emitted at all.
      io << "\e[0m" if color && !current.plain?
    end
  end

  # The palette used across the UI — 256-colour codes, which every terminal
  # smith realistically meets understands.
  module Palette
    USER      =  39 # blue
    ASSISTANT = 252
    TOOL      = 179 # tan/yellow
    SUCCESS   =  71 # green
    ERROR     = 167 # red
    WARN      = 179
    INFO      = 245 # grey
    ACCENT    =  75 # light blue
    THINKING  = 245
    BORDER    = 240
    CODE      = 114
    HEADING   =  75
    LINK      =  75
    TODO_DONE = 245
    MODE_PLAN = 214 # orange
  end
end
