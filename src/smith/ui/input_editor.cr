require "anvil"
require "./terminal"

module Smith::UI
  # The prompt's line editor.
  #
  # The editing itself — grapheme-aware cursor movement, history with a saved
  # draft, the readline-style Ctrl keys, horizontal scrolling — lives in
  # `Anvil::Widgets::InputEditor`. What is left here is the translation from
  # smith's own `Key` to the event type anvil speaks.
  #
  # That translation is temporary: once the key loop itself comes from anvil,
  # smith's `Key` disappears and this class with it.
  class InputEditor
    getter inner : Anvil::Widgets::InputEditor

    def initialize(history : Array(String) = Array(String).new, max_history : Int32 = 500)
      @inner = Anvil::Widgets::InputEditor.new(history, max_history)
    end

    delegate text, empty?, reset, set_text, columns_before_cursor, display_width,
      history, cursor, view, to: @inner

    def handle(key : Key) : String?
      # A paste arrives here as one key carrying the whole payload, where
      # anvil expects the terminal's start/end brackets around the characters.
      # Handing it straight to the editor keeps both models happy.
      if key.kind.paste?
        @inner.insert_text(key.text || "")
        return nil
      end

      event = to_event(key)
      event ? @inner.handle(event) : nil
    end

    # nil for everything the editor has no business with — Escape, Tick,
    # Resized, Eof — which the app loop handles instead.
    private def to_event(key : Key) : Termisu::Event::Key?
      kind = key.kind
      case kind
      when .char?
        char = key.char
        return nil unless char
        Termisu::Event::Key.new(Termisu::Input::Key.from_char(char), char: char)
      when .ctrl?
        char = key.char
        return nil unless char
        Termisu::Event::Key.new(Termisu::Input::Key.from_char(char),
          Termisu::Input::Modifier::Ctrl)
      when .enter?     then special(Termisu::Input::Key::Enter)
      when .backspace? then special(Termisu::Input::Key::Backspace)
      when .delete?    then special(Termisu::Input::Key::Delete)
      when .left?      then special(Termisu::Input::Key::Left)
      when .right?     then special(Termisu::Input::Key::Right)
      when .home?      then special(Termisu::Input::Key::Home)
      when .end?       then special(Termisu::Input::Key::End)
      when .up?        then special(Termisu::Input::Key::Up)
      when .down?      then special(Termisu::Input::Key::Down)
      else                  nil
      end
    end

    private def special(key : Termisu::Input::Key) : Termisu::Event::Key
      Termisu::Event::Key.new(key)
    end
  end
end
