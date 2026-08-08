require "./scripted_io"

# A grid terminal, just complete enough to replay what the App writes: text,
# CR/LF, cursor up/down, cursor-to-column and the two erase-line forms. Lines
# pushed off the top are kept, which is what the in-place redraw must never
# do with the live region.
class Screen
  getter scrollback : Array(String)

  def initialize(@width : Int32 = 80, @height : Int32 = 24)
    @grid = Array(Array(Char)).new(@height) { Array(Char).new(@width, ' ') }
    @scrollback = [] of String
    @row = 0
    @col = 0
  end

  def self.replay(bytes : String, width : Int32 = 80, height : Int32 = 24) : Screen
    new(width, height).feed(bytes)
  end

  # Everything the terminal has ever shown: what scrolled away plus what is
  # still on screen.
  def all_lines : Array(String)
    @scrollback + @grid.map(&.join.rstrip)
  end

  def screen_lines : Array(String)
    @grid.map(&.join.rstrip)
  end

  def feed(bytes : String) : Screen
    data = bytes.to_slice
    i = 0

    while i < data.size
      byte = data[i]
      i += 1

      case byte
      when 0x0D_u8 then @col = 0
      when 0x0A_u8 then line_feed
      when 0x1B_u8
        next unless data[i]? == '['.ord.to_u8
        i += 1
        params = String.build do |io|
          while (b = data[i]?) && b >= 0x20_u8 && b <= 0x3F_u8
            io << b.chr
            i += 1
          end
        end
        final = data[i]?.try(&.chr)
        i += 1
        apply_csi(params, final)
      else
        length = byte >= 0xF0_u8 ? 4 : (byte >= 0xE0_u8 ? 3 : (byte >= 0xC0_u8 ? 2 : 1))
        char = String.new(data[i - 1, length]).each_char.first? || '?'
        i += length - 1
        put(char)
      end
    end

    self
  end

  private def apply_csi(params : String, final : Char?) : Nil
    n = params.gsub(/[^0-9]/, "").to_i? || 0
    n = 1 if n.zero?

    case final
    when 'A' then @row = {@row - n, 0}.max
    when 'B' then @row = {@row + n, @height - 1}.min
    when 'G' then @col = {n - 1, @width - 1}.min
    when 'H' then @row = 0; @col = 0
    when 'J' then @grid.each_index { |r| @grid[r] = Array(Char).new(@width, ' ') }
    when 'K'
      if params.includes?("2")
        @grid[@row] = Array(Char).new(@width, ' ')
      else
        (@col...@width).each { |x| @grid[@row][x] = ' ' }
      end
    end
  end

  private def put(char : Char) : Nil
    if @col >= @width
      @col = 0
      line_feed
    end
    @grid[@row][@col] = char
    @col += 1
  end

  private def line_feed : Nil
    @row += 1
    return if @row < @height

    @scrollback << @grid.shift.join.rstrip
    @grid << Array(Char).new(@width, ' ')
    @row = @height - 1
  end
end
