require "json"
require "./style"
require "./markdown"
require "../todos"

module Smith::UI
  # Blocks are what the TUI draws: every event becomes one, and the renderer
  # decides which are already on screen (flushed) and which are still live.
  #
  # `lines` must be free of IO — blocks are mutated by the turn fiber and read
  # by the draw fiber, and the only thing keeping that safe is that neither
  # side yields mid-operation.
  abstract class Block
    abstract def lines(width : Int32) : Array(StyledLine)

    # Whether the block has stopped changing, and can therefore be printed
    # into the scrollback once and never redrawn. Most blocks arrive finished;
    # the streaming ones say when they are done.
    def finalized? : Bool
      true
    end
  end

  # How long a block has been running, in the shortest form that stays
  # readable. Shared by everything that shows an elapsed time.
  def self.format_duration(span : Time::Span) : String
    total = span.total_seconds
    if total < 10
      "#{total.round(1)}s"
    elsif total < 60
      "#{total.round(0).to_i}s"
    elsif total < 3600
      "#{(total / 60).floor.to_i}m#{(total % 60).floor.to_i}s"
    else
      "#{(total / 3600).floor.to_i}h#{((total % 3600) / 60).floor.to_i}m"
    end
  end

  class UserBlock < Block
    def initialize(@text : String)
    end

    def lines(width : Int32) : Array(StyledLine)
      prefix = [Span.new("❯ ", Style.new(fg: Palette::USER, bold: true))]
      wrapped = LineUtil.wrap(Markdown.inline(@text), width - 2)
      wrapped = [LineUtil::EMPTY_LINE] if wrapped.empty?

      wrapped.each_with_index.map do |line, i|
        (i.zero? ? prefix : [Span.new("  ")]) + line
      end.to_a
    end
  end

  class AssistantBlock < Block
    property buffer : String
    property? live : Bool

    def initialize(@buffer : String = "", @live : Bool = true)
    end

    def finalized? : Bool
      !live?
    end

    def lines(width : Int32) : Array(StyledLine)
      out = Markdown.render(@buffer, width)
      out = [LineUtil::EMPTY_LINE] if out.empty?

      # A visible cursor at the stream's edge, so waiting on the first token
      # does not look like a hang.
      if live? && (last = out.last?) && !last.empty?
        out[-1] = last + [Span.new("▊", Style.new(dim: true))]
      end
      out
    end
  end

  class ThinkingBlock < Block
    property buffer : String
    property? live : Bool
    getter started_at : Time::Instant

    def initialize(@started_at : Time::Instant = Time.instant, @buffer : String = "", @live : Bool = true)
    end

    def elapsed : Time::Span
      Time.instant - @started_at
    end

    def finalized? : Bool
      !live?
    end

    def lines(width : Int32) : Array(StyledLine)
      unless live?
        return [[Span.new("✻ Thinking (#{UI.format_duration(elapsed)})", Style.new(fg: Palette::THINKING, dim: true))]]
      end

      style = Style.new(fg: Palette::THINKING, dim: true, italic: true)
      wrapped = LineUtil.wrap([Span.new(@buffer, style)], width - 2)
      wrapped.each_with_index.map do |line, i|
        prefix = i.zero? ? [Span.new("✻ ", Style.new(fg: Palette::THINKING))] : [Span.new("  ")]
        prefix + line
      end.to_a
    end
  end

  class ToolBlock < Block
    enum Status
      Running
      Done
      Failed
    end

    getter id : String
    getter name : String
    getter summary : String
    property status : Status
    property result : String
    getter started_at : Time::Instant

    def initialize(@id : String, @name : String, @summary : String,
                   @status : Status = Status::Running, @result : String = "",
                   @started_at : Time::Instant = Time.instant)
    end

    def elapsed : Time::Span
      Time.instant - @started_at
    end

    def finalized? : Bool
      !@status.running?
    end

    def lines(width : Int32) : Array(StyledLine)
      check, status_style = case @status
                            in Status::Running
                              {Spinner.frame, Style.new(fg: Palette::ACCENT)}
                            in Status::Done
                              {"✓", Style.new(fg: Palette::SUCCESS)}
                            in Status::Failed
                              {"✗", Style.new(fg: Palette::ERROR)}
                            end

      head = StyledLine.new
      head << Span.new("#{check} ", status_style)
      head << Span.new(@name, Style.new(bold: true))
      unless @summary.empty?
        head << Span.new(" · ", Style.new(fg: Palette::BORDER))
        head << Span.new(@summary, Style.new(dim: true))
      end
      suffix = @status.running? ? " #{UI.format_duration(elapsed)}" : " (#{UI.format_duration(elapsed)})"
      head << Span.new(suffix, Style.new(fg: Palette::INFO))

      out = LineUtil.wrap(head, width)

      # A failed tool shows the first lines of why — the model sees the full
      # text anyway; this is for the human watching.
      if @status.failed? && !@result.empty?
        @result.lines.first(3).each do |line|
          LineUtil.wrap([Span.new(line, Style.new(fg: Palette::ERROR, dim: true))], width - 2).each do |l|
            out << [Span.new("  ")] + l
          end
        end
      end

      out
    end

    # The one argument a human recognizes the call by.
    def self.summarize(args : JSON::Any) : String
      %w[command path pattern query url prompt].each do |key|
        if value = args[key]?.try(&.as_s?)
          return value.gsub(/\s+/, " ").strip[0, 200]
        end
      end
      args.to_json[0, 120]
    end
  end

  class TodosBlock < Block
    getter items : Array(Smith::TodoList::Item)

    def initialize(@items : Array(Smith::TodoList::Item))
    end

    def lines(width : Int32) : Array(StyledLine)
      done = @items.count(&.status.completed?)
      header = StyledLine.new
      header << Span.new("☰ ", Style.new(fg: Palette::ACCENT))
      header << Span.new("Todos", Style.new(bold: true))
      header << Span.new("  #{done}/#{@items.size}", Style.new(fg: Palette::INFO))

      out = [header]
      @items.each do |item|
        mark, style = case item.status
                      when .completed?
                        {"☑", Style.new(fg: Palette::TODO_DONE)}
                      when .in_progress?
                        {"▶", Style.new(fg: Palette::ACCENT, bold: true)}
                      else
                        {"☐", Style.new(fg: Palette::INFO)}
                      end
        text_style = item.status.completed? ? Style.new(dim: true) : Style::NONE

        LineUtil.wrap([Span.new(item.content, text_style)], width - 4).each_with_index do |l, i|
          prefix = i.zero? ? [Span.new("#{mark} ", style)] : [Span.new("   ")]
          out << prefix + l
        end
      end
      out
    end
  end

  class NoticeBlock < Block
    def initialize(@lines : Array(StyledLine))
    end

    def self.text(text : String, style : Style = Style.new(fg: Palette::INFO)) : NoticeBlock
      new([LineUtil.line(text, style)])
    end

    def lines(width : Int32) : Array(StyledLine)
      out = Array(StyledLine).new
      @lines.each { |l| out.concat(LineUtil.wrap(l, width)) }
      out
    end
  end

  module Spinner
    FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    # Time-driven via the wall clock — the frame only needs to change at a
    # steady rate, and using the clock keeps redraw frequency irrelevant.
    # The math stays in Int64: unix milliseconds do not fit into an Int32.
    def self.frame(now_ms : Int64 = Time.utc.to_unix_ms) : String
      index = (((now_ms // 80) % FRAMES.size.to_i64).abs).to_i
      FRAMES[index]
    end
  end
end
