require "../../spec_helper"
require "../../../src/smith/ui/terminal"
require "../../../src/smith/ui/input_editor"

include Smith::UI

# Feeds a sequence of keys into the editor, returning whatever was submitted.
private def type_into(editor : Smith::UI::InputEditor, keys : Array(Smith::UI::Key)) : String?
  submitted = nil
  keys.each { |key| submitted = editor.handle(key) unless submitted }
  submitted
end

private def chars(text : String) : Array(Smith::UI::Key)
  text.chars.map { |c| Key.char(c) }
end

describe Smith::UI::InputEditor do
  it "collects characters until Enter submits" do
    editor = InputEditor.new
    submitted = type_into(editor, chars("hi") + [Key.enter])
    submitted.should eq("hi")
    editor.empty?.should be_true
  end

  it "does not submit on a non-Enter key" do
    editor = InputEditor.new
    type_into(editor, chars("ab"))
    editor.text.should eq("ab")
  end

  it "submits an empty buffer as an empty string" do
    editor = InputEditor.new
    submitted = type_into(editor, [Key.enter])
    submitted.should eq("")
  end

  it "ignores non-editing keys like Tick and Resized" do
    editor = InputEditor.new
    type_into(editor, chars("a") + [Key.tick, Key.resized] + chars("b"))
    editor.text.should eq("ab")
  end

  describe "backspace" do
    it "removes the character before the cursor" do
      editor = InputEditor.new
      type_into(editor, chars("abc") + [Key.backspace])
      editor.text.should eq("ab")
    end

    it "is a no-op on an empty buffer" do
      editor = InputEditor.new
      type_into(editor, [Key.backspace])
      editor.empty?.should be_true
    end
  end

  describe "cursor movement" do
    it "moves left and right within bounds" do
      editor = InputEditor.new
      type_into(editor, chars("ab") + [Key.left, Key.left, Key.left, Key.char('c')])
      editor.text.should eq("cab")

      # Cursor is at 1; one right lands between a and b, one more at the end.
      type_into(editor, [Key.right, Key.char('d')])
      editor.text.should eq("cadb")

      type_into(editor, [Key.right, Key.right, Key.right, Key.char('e')])
      editor.text.should eq("cadbe")
    end

    it "supports Home and End" do
      editor = InputEditor.new
      type_into(editor, chars("ab") + [Key.home, Key.char('x')])
      editor.text.should eq("xab")

      type_into(editor, [Key.end, Key.char('z')])
      editor.text.should eq("xabz")
    end
  end

  describe "delete" do
    it "removes the character under the cursor" do
      editor = InputEditor.new
      type_into(editor, chars("ab") + [Key.home, Key.delete])
      editor.text.should eq("b")
    end
  end

  describe "history" do
    it "records submitted entries" do
      editor = InputEditor.new
      type_into(editor, chars("one") + [Key.enter])
      type_into(editor, chars("two") + [Key.enter])
      editor.history.should eq(["one", "two"])
    end

    it "does not record blank submissions" do
      editor = InputEditor.new
      type_into(editor, chars("   ") + [Key.enter])
      editor.history.should be_empty
    end

    it "recalls entries with Up and returns to the draft with Down" do
      editor = InputEditor.new
      type_into(editor, chars("one") + [Key.enter])
      type_into(editor, chars("two") + [Key.enter])

      type_into(editor, chars("draft") + [Key.up])
      editor.text.should eq("two")
      type_into(editor, [Key.up])
      editor.text.should eq("one")
      type_into(editor, [Key.up])
      editor.text.should eq("one") # stays at the oldest
      type_into(editor, [Key.down])
      editor.text.should eq("two")
      type_into(editor, [Key.down])
      editor.text.should eq("draft")
    end

    it "collapses consecutive duplicates" do
      editor = InputEditor.new
      2.times { type_into(editor, chars("same") + [Key.enter]) }
      editor.history.should eq(["same"])
    end

    it "caps the history at max_history" do
      editor = InputEditor.new(max_history: 2)
      %w[a b c].each { |s| type_into(editor, chars(s) + [Key.enter]) }
      editor.history.should eq(["b", "c"])
    end
  end

  describe "reset" do
    it "clears buffer, cursor and history position" do
      editor = InputEditor.new
      type_into(editor, chars("x") + [Key.enter])
      type_into(editor, chars("y") + [Key.up])
      editor.text.should eq("x")
      editor.reset
      editor.empty?.should be_true
    end
  end

  describe "set_text" do
    it "replaces the buffer and parks the cursor at the end" do
      editor = InputEditor.new
      type_into(editor, chars("half"))
      editor.set_text("/resume ")
      editor.text.should eq("/resume ")

      # Typing continues where completion left off.
      type_into(editor, chars("target") + [Key.enter])
      editor.history.should eq(["/resume target"])
    end
  end

  describe "columns_before_cursor" do
    it "counts display columns for wide characters" do
      editor = InputEditor.new
      type_into(editor, chars("你a"))
      editor.columns_before_cursor.should eq(3)
    end
  end
end
