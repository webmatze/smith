require "./terminal"
require "./style"

module Smith::UI
  # The prompt's single line of input. One line on purpose: everything the
  # agent takes is one prompt, and multi-line editing buys little here while
  # complicating the layout. History is what makes it comfortable.
  class InputEditor
    getter history : Array(String)

    @buffer : Array(Char) = Array(Char).new
    @cursor : Int32 = 0
    @history_index : Int32? = nil
    @draft : String = ""

    def initialize(@history : Array(String) = Array(String).new, @max_history : Int32 = 500)
    end

    def text : String
      @buffer.join
    end

    def empty? : Bool
      @buffer.empty?
    end

    def reset : Nil
      @buffer = Array(Char).new
      @cursor = 0
      @history_index = nil
      @draft = ""
    end

    # Handles one key. Returns the submitted text when Enter was pressed,
    # nil otherwise.
    def handle(key : Key) : String?
      case key.kind
      in Key::Kind::Char
        insert(key.char.not_nil!.to_s)
      in Key::Kind::Paste
        # Pasted newlines would break the one-line layout; flatten them.
        insert(key.text.not_nil!.gsub(/\s*\n\s*/, " "))
      in Key::Kind::Backspace
        if @cursor > 0
          @buffer.delete_at(@cursor - 1)
          @cursor -= 1
        end
      in Key::Kind::Delete
        @buffer.delete_at(@cursor) if @cursor < @buffer.size
      in Key::Kind::Left
        @cursor -= 1 if @cursor > 0
      in Key::Kind::Right
        @cursor += 1 if @cursor < @buffer.size
      in Key::Kind::Home
        @cursor = 0
      in Key::Kind::End
        @cursor = @buffer.size
      in Key::Kind::Up
        history_previous
      in Key::Kind::Down
        history_next
      in Key::Kind::Ctrl
        handle_ctrl(key.char)
      in Key::Kind::Enter
        return submit
      in Key::Kind::Newline, Key::Kind::Escape, Key::Kind::Tick,
         Key::Kind::Resized, Key::Kind::Eof, Key::Kind::Unknown
        # Not editing keys — the app loop deals with them.
      end
      nil
    end

    private def handle_ctrl(char : Char?) : Nil
      case char
      when 'a' then @cursor = 0
      when 'e' then @cursor = @buffer.size
      when 'b' then @cursor -= 1 if @cursor > 0
      when 'f' then @cursor += 1 if @cursor < @buffer.size
      when 'u' # kill to start
        @buffer = @buffer[@cursor..]
        @cursor = 0
      when 'k' # kill to end
        @buffer = @buffer[0...@cursor]
      when 'w' # kill word back
        i = @cursor
        while i > 0 && @buffer[i - 1] == ' '
          i -= 1
        end
        while i > 0 && @buffer[i - 1] != ' '
          i -= 1
        end
        @buffer = @buffer[0...i] + @buffer[@cursor..]
        @cursor = i
      end
    end

    private def insert(text : String) : Nil
      chars = text.chars
      @buffer = @buffer[0...@cursor] + chars + @buffer[@cursor..]
      @cursor += chars.size
    end

    private def submit : String
      submitted = text
      reset
      unless submitted.strip.empty?
        @history.pop? if @history.last? == submitted
        @history << submitted
        @history.shift if @history.size > @max_history
      end
      submitted
    end

    private def history_previous : Nil
      return if @history.empty?

      index = @history_index
      if index.nil?
        @draft = text
        @history_index = @history.size - 1
      elsif index > 0
        @history_index = index - 1
      else
        return
      end
      load_history
    end

    private def history_next : Nil
      index = @history_index
      return if index.nil?

      if index >= @history.size - 1
        @history_index = nil
        replace(@draft)
        @draft = ""
      else
        @history_index = index + 1
        load_history
      end
    end

    private def load_history : Nil
      if entry = @history_index.try { |i| @history[i]? }
        replace(entry)
      end
    end

    private def replace(text : String) : Nil
      @buffer = text.chars
      @cursor = @buffer.size
    end

    # Replaces the whole buffer, cursor to the end — what the autocomplete
    # popup does when it completes a command.
    def set_text(text : String) : Nil
      replace(text)
    end

    # Columns the text occupies up to (excluding) the cursor.
    def columns_before_cursor : Int32
      Style.display_width(@buffer[0...@cursor].join)
    end

    def display_width : Int32
      Style.display_width(text)
    end
  end
end
