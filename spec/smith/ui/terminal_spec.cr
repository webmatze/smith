require "../../spec_helper"
require "../../../src/smith/ui/terminal"

include Smith::UI

private def parse(bytes : String) : Smith::UI::Key?
  Smith::UI::KeyParser.parse(IO::Memory.new(bytes))
end

describe Smith::UI::KeyParser do
  describe "simple bytes" do
    it "parses CR as Enter" do
      parse("\r").not_nil!.kind.enter?.should be_true
    end

    it "parses LF as Newline" do
      parse("\n").not_nil!.kind.newline?.should be_true
    end

    it "parses DEL and BS as Backspace" do
      parse("\x7F").not_nil!.kind.backspace?.should be_true
      parse("\b").not_nil!.kind.backspace?.should be_true
    end

    it "parses Tab as a char" do
      key = parse("\t").not_nil!
      key.kind.char?.should be_true
      key.char.should eq('\t')
    end

    it "parses Ctrl-A through Ctrl-Z" do
      parse("\x01").not_nil!.char.should eq('a')
      parse("\x03").not_nil!.kind.ctrl?.should be_true
      parse("\x03").not_nil!.char.should eq('c')
      parse("\x1A").not_nil!.char.should eq('z')
    end

    it "parses Ctrl-Space" do
      key = parse("\x00").not_nil!
      key.kind.ctrl?.should be_true
      key.char.should eq(' ')
    end

    it "parses a printable character" do
      key = parse("x").not_nil!
      key.kind.char?.should be_true
      key.char.should eq('x')
    end

    it "parses a multi-byte UTF-8 character" do
      key = parse("好").not_nil!
      key.kind.char?.should be_true
      key.char.should eq('好')
    end

    it "returns nil at EOF" do
      parse("").should be_nil
    end
  end

  describe "escape sequences" do
    it "parses CSI arrows" do
      parse("\e[A").not_nil!.kind.up?.should be_true
      parse("\e[B").not_nil!.kind.down?.should be_true
      parse("\e[C").not_nil!.kind.right?.should be_true
      parse("\e[D").not_nil!.kind.left?.should be_true
    end

    it "parses CSI Home and End" do
      parse("\e[H").not_nil!.kind.home?.should be_true
      parse("\e[F").not_nil!.kind.end?.should be_true
    end

    it "parses tilde-final navigation keys" do
      parse("\e[3~").not_nil!.kind.delete?.should be_true
      parse("\e[1~").not_nil!.kind.home?.should be_true
      parse("\e[4~").not_nil!.kind.end?.should be_true
      parse("\e[8~").not_nil!.kind.end?.should be_true
    end

    it "parses SS3 arrows from application mode" do
      parse("\eOA").not_nil!.kind.up?.should be_true
      parse("\eOB").not_nil!.kind.down?.should be_true
      parse("\eOC").not_nil!.kind.right?.should be_true
      parse("\eOD").not_nil!.kind.left?.should be_true
    end

    it "parses Alt+Enter as Newline" do
      parse("\e\r").not_nil!.kind.newline?.should be_true
    end

    it "parses a bare ESC as Escape" do
      parse("\e").not_nil!.kind.escape?.should be_true
    end

    it "reports Escape for an ESC + unknown letter" do
      parse("\ex").not_nil!.kind.escape?.should be_true
    end

    it "returns Unknown for a truncated CSI sequence" do
      parse("\e[").not_nil!.kind.unknown?.should be_true
    end
  end

  describe "bracketed paste" do
    it "returns the payload verbatim" do
      key = parse("\e[200~pasted text\e[201~").not_nil!
      key.kind.paste?.should be_true
      key.text.should eq("pasted text")
    end

    it "keeps newlines inside the payload" do
      key = parse("\e[200~line1\nline2\e[201~").not_nil!
      key.text.should eq("line1\nline2")
    end

    it "keeps stray escape sequences inside the payload" do
      key = parse("\e[200~keep \e[31mcolor\e[201~").not_nil!
      key.text.should eq("keep \e[31mcolor")
    end

    it "treats EOF as the end of the payload" do
      key = parse("\e[200~unterminated").not_nil!
      key.kind.paste?.should be_true
      key.text.should eq("unterminated")
    end
  end
end

describe Smith::UI::Key do
  it "exposes the kind helpers" do
    Key.enter.kind.enter?.should be_true
    Key.char('x').kind.char?.should be_true
    Key.ctrl('c').kind.ctrl?.should be_true
    Key.tick.kind.tick?.should be_true
  end

  it "carries its payload" do
    Key.char('q').char.should eq('q')
    Key.paste("data").text.should eq("data")
  end
end

describe Smith::UI::Terminal do
  it "reports the injected size without touching the real terminal" do
    terminal = Terminal.new(IO::Memory.new, IO::Memory.new, width: 100, height: 30)
    terminal.size.should eq({100, 30})
    terminal.width.should eq(100)
    terminal.height.should eq(30)
  end

  it "reads keys from a memory buffer and ends at Eof" do
    terminal = Terminal.new(IO::Memory.new, IO::Memory.new("ab"))
    terminal.read_key.kind.char?.should be_true
    terminal.read_key.kind.char?.should be_true
    terminal.read_key.kind.eof?.should be_true
  end

  it "does not enter raw mode for non-FD inputs" do
    terminal = Terminal.new(IO::Memory.new, IO::Memory.new)
    terminal.enter!
    terminal.raw?.should be_false
  end

  it "respects the resized flag" do
    terminal = Terminal.new(IO::Memory.new, IO::Memory.new)
    terminal.resized?.should be_false
    terminal.clear_resize!
    terminal.resized?.should be_false
  end
end
