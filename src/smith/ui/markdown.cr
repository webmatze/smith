require "./style"

module Smith::UI
  # A deliberately small markdown renderer — enough of CommonMark that model
  # output reads well, without pulling in a parser dependency. Streaming
  # passes text that ends mid-token, so everything here is per-line and
  # tolerant of an unfinished final line.
  module Markdown
    extend self

    # Renders the given markdown into styled lines, wrapped to `width`.
    def render(text : String, width : Int32, color : Bool = true) : Array(StyledLine)
      lines = Array(StyledLine).new
      code_lines : Array(StyledLine)? = nil
      code_style = Style.new(fg: Palette::CODE)

      text.each_line do |raw|
        # Inside a fence: everything is code until the closing fence.
        if open = code_lines
          if raw.strip.starts_with?("```")
            lines.concat(open)
            lines << fence_line("```")
            code_lines = nil
          else
            open.concat(wrap_plain(raw, width, code_style))
          end
          next
        end

        stripped = raw.strip

        if stripped.starts_with?("```")
          label = stripped.lstrip('`').strip
          header = label.empty? ? "```" : "``` #{label}"
          lines << fence_line(header)
          code_lines = Array(StyledLine).new
          next
        end

        if stripped.empty?
          lines << LineUtil::EMPTY_LINE
          next
        end

        # Headings
        if stripped.starts_with?('#')
          level = 0
          stripped.each_char { |c| break unless c == '#'; level += 1 }
          if level <= 6 && stripped[level]?.try(&.ascii_whitespace?)
            style = Style.new(fg: Palette::HEADING, bold: true)
            lines.concat(wrap_plain(stripped[level + 1..].strip, width, style))
            next
          end
        end

        # Horizontal rule
        if stripped.matches?(/^[-*_]{3,}$/)
          lines << [Span.new("─" * {width, 40}.min, Style.new(fg: Palette::BORDER))]
          next
        end

        # Blockquote
        if stripped.starts_with?('>')
          content = stripped.lstrip('>').strip
          style = Style.new(fg: Palette::INFO, dim: true)
          wrapped = LineUtil.wrap(inline(content, style), width - 2)
          wrapped.each { |l| lines << [Span.new("▐ ", Style.new(fg: Palette::BORDER))] + l }
          next
        end

        # Unordered list
        if m = stripped.match(/^([-*+])\s+(.*)$/)
          content = m[2]
          checkbox = nil
          if cb = content.match(/^\[([ xX])\]\s+(.*)$/)
            checkbox = cb[1]
            content = cb[2]
          end

          bullet = case checkbox
                   when "x", "X" then "☑"
                   when " "      then "☐"
                   else               "•"
                   end
          bullet_style = if checkbox
                           checkbox == " " ? Style.new(fg: Palette::INFO) : Style.new(fg: Palette::SUCCESS)
                         else
                           Style.new(fg: Palette::ACCENT)
                         end

          body_style = checkbox == " " ? Style.new(dim: true) : Style::NONE
          wrapped = LineUtil.wrap(inline(content, body_style), width - 2)
          wrapped.each_with_index do |l, i|
            prefix = i.zero? ? [Span.new("#{bullet} ", bullet_style)] : [Span.new("  ")]
            lines << prefix + l
          end
          next
        end

        # Ordered list
        if m = stripped.match(/^(\d+)[.)]\s+(.*)$/)
          number = m[1]
          content = m[2]
          prefix_text = "#{number}. "
          wrapped = LineUtil.wrap(inline(content), width - prefix_text.size - 1)
          wrapped.each_with_index do |l, i|
            prefix = i.zero? ? [Span.new(prefix_text, Style.new(fg: Palette::ACCENT))] : [Span.new(" " * (prefix_text.size))]
            lines << prefix + l
          end
          next
        end

        lines.concat(LineUtil.wrap(inline(stripped), width))
      end

      # An unterminated fence at the stream's edge: show what there is,
      # without closing it.
      if open = code_lines
        lines.concat(open)
      end

      lines
    end

    private def fence_line(text : String) : StyledLine
      [Span.new(text, Style.new(fg: Palette::BORDER))]
    end

    private def wrap_plain(text : String, width : Int32, style : Style) : Array(StyledLine)
      LineUtil.wrap([Span.new(text, style)], width)
    end

    # Inline formatting: **bold**, *italic*, `code`, ~~strike~~ and
    # [links](url). Deliberately simple; nesting is not supported.
    def inline(text : String, base : Style = Style::NONE) : StyledLine
      spans = StyledLine.new
      i = 0
      chars = text.chars

      while i < chars.size
        # Inline code
        if chars[i] == '`'
          closing = chars.index('`', i + 1)
          if closing
            spans << Span.new(chars[(i + 1)...closing].join, base.merge(Style.new(fg: Palette::CODE)))
            i = closing + 1
            next
          end
        end

        # Bold
        if chars[i] == '*' && chars[i + 1]? == '*'
          closing = find_double(chars, i + 2)
          if closing
            spans << Span.new(chars[(i + 2)...closing].join, base.merge(Style.new(bold: true)))
            i = closing + 2
            next
          end
        end

        # Italic (single *), but not when it is part of an unclosed bold.
        if chars[i] == '*' && chars[i + 1]? != '*'
          closing = chars.index('*', i + 1)
          if closing && closing > i + 1
            spans << Span.new(chars[(i + 1)...closing].join, base.merge(Style.new(italic: true)))
            i = closing + 1
            next
          end
        end

        # Strikethrough
        if chars[i] == '~' && chars[i + 1]? == '~'
          closing = find_double_tilde(chars, i + 2)
          if closing
            inner = chars[(i + 2)...closing].join
            spans << Span.new(inner, base.merge(Style.new(dim: true)))
            i = closing + 2
            next
          end
        end

        # Link — show text, drop the url.
        if chars[i] == '['
          closing = chars.index(']', i + 1)
          if closing && chars[closing + 1]? == '('
            paren = chars.index(')', closing + 2)
            if paren
              spans << Span.new(chars[(i + 1)...closing].join, base.merge(Style.new(fg: Palette::LINK, underline: true)))
              i = paren + 1
              next
            end
          end
        end

        # Plain run: gather until the next marker to keep the span count low.
        start = i
        i += 1
        while i < chars.size && !marker?(chars[i], chars[i + 1]?)
          i += 1
        end
        spans << Span.new(chars[start...i].join, base)
      end

      spans
    end

    private def marker?(ch : Char, next_ch : Char?) : Bool
      case ch
      when '`', '*', '~', '[' then true
      else                         false
      end
    end

    private def find_double(chars : Array(Char), from : Int32) : Int32?
      i = from
      while i < chars.size - 1
        return i if chars[i] == '*' && chars[i + 1] == '*'
        i += 1
      end
      nil
    end

    private def find_double_tilde(chars : Array(Char), from : Int32) : Int32?
      i = from
      while i < chars.size - 1
        return i if chars[i] == '~' && chars[i + 1] == '~'
        i += 1
      end
      nil
    end
  end
end
