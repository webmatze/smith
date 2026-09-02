require "../../spec_helper"
require "../../../src/smith/ui/style"

include Smith::UI

private def plain_text(line : Smith::UI::StyledLine) : String
  Smith::UI::LineUtil.plain(line)
end

describe Smith::UI::Style do
  describe "#merge" do
    it "lets the overlay win wherever it is set" do
      base = Style.new(fg: Color.ansi256(10), bold: true)
      overlay = Style.new(fg: Color.ansi256(20))

      merged = base.merge(overlay)
      merged.fg.should eq(Color.ansi256(20))
      merged.bold?.should be_true
    end

    it "keeps base attributes the overlay leaves unset" do
      base = Style.new(dim: true, italic: true)
      overlay = Style.new(underline: true)

      merged = base.merge(overlay)
      merged.dim?.should be_true
      merged.italic?.should be_true
      merged.underline?.should be_true
    end
  end

  describe "#plain?" do
    it "is true only when nothing is set" do
      Style::NONE.plain?.should be_true
      Style.new(fg: Color.ansi256(1)).plain?.should be_false
      Style.new(bold: true).plain?.should be_false
    end
  end

  describe "#ansi" do
    it "emits nothing for a plain style" do
      Style::NONE.ansi.should eq("")
    end

    it "combines flags and colour in one sequence" do
      ansi = Style.new(fg: Color.ansi256(42), bold: true).ansi
      ansi.should contain("1")
      ansi.should contain("38;5;42")
      ansi.should start_with("\e[")
      ansi.should end_with("m")
    end
  end

  describe ".display_width" do
    it "counts ASCII as one column each" do
      LineUtil.width("hello").should eq(5)
    end

    it "counts CJK and most emoji as two columns" do
      LineUtil.width("你").should eq(2)
      LineUtil.width("😀").should eq(2)
    end

    it "treats zero-width characters as width 0" do
      # U+200B zero-width space.
      LineUtil.width("a\u200Bb").should eq(2)
    end
  end

  describe ".char_width" do
    it "classifies individual characters" do
      LineUtil.grapheme_width('a'.to_s).should eq(1)
      LineUtil.grapheme_width('好'.to_s).should eq(2)
    end
  end
end

describe Smith::UI::LineUtil do
  describe ".wrap" do
    it "keeps short lines whole" do
      lines = LineUtil.wrap([Span.new("hello")], 20)
      lines.size.should eq(1)
      plain_text(lines[0]).should eq("hello")
    end

    it "breaks at word boundaries" do
      lines = LineUtil.wrap([Span.new("the quick brown fox")], 10)
      lines.map { |l| plain_text(l) }.should eq(["the quick", "brown fox"])
    end

    it "hard-breaks a word longer than the width" do
      lines = LineUtil.wrap([Span.new("abcdefgh")], 3)
      lines.map { |l| plain_text(l) }.should eq(["abc", "def", "gh"])
    end

    it "drops a space that would wrap" do
      # 'abc ' is exactly 4 wide; the trailing space must not carry over.
      lines = LineUtil.wrap([Span.new("abc def")], 4)
      lines.map { |l| plain_text(l) }.should eq(["abc", "def"])
    end

    it "preserves existing newlines" do
      lines = LineUtil.wrap([Span.new("a\nb")], 20)
      lines.map { |l| plain_text(l) }.should eq(["a", "b"])
    end

    it "keeps styles on wrapped pieces" do
      bold = Style.new(bold: true)
      lines = LineUtil.wrap([Span.new("aa bb", bold)], 3)
      lines.size.should eq(2)
      lines[0][0].style.should eq(bold)
      lines[1][0].style.should eq(bold)
    end

    it "clamps a non-positive width to one column" do
      lines = LineUtil.wrap([Span.new("ab")], 0)
      lines.map { |l| plain_text(l) }.should eq(["a", "b"])
    end
  end

  describe ".truncate" do
    it "leaves a fitting line untouched" do
      line = [Span.new("hi")] of Smith::UI::Span
      LineUtil.truncate(line, 10).should eq(line)
    end

    it "cuts to the budget" do
      result = LineUtil.truncate([Span.new("abcdef")], 3)
      _text = plain_text(result)
      _text.should eq("abc")
    end

    it "appends the ellipsis within the budget" do
      result = LineUtil.truncate([Span.new("abcdef")], 4, ellipsis: "…")
      _text = plain_text(result)
      _text.should eq("abc…")
    end

    it "does not split a double-width character" do
      result = LineUtil.truncate([Span.new("a好")], 2)
      _text = plain_text(result)
      _text.should eq("a")
    end
  end

  describe ".to_ansi / .render" do
    it "emits plain text when colour is off" do
      result = LineUtil.to_ansi([Span.new("x", Style.new(bold: true))], color: false)
      result.should eq("x")
    end

    it "wraps styled spans in SGR sequences" do
      result = LineUtil.to_ansi([Span.new("x", Style.new(bold: true))])
      result.should start_with("\e[")
      result.should contain("x")
      result.should end_with("\e[0m")
    end

    it "resets between differently styled spans" do
      a = Span.new("a", Style.new(bold: true))
      b = Span.new("b", Style.new(fg: Color.ansi256(5)))
      result = LineUtil.to_ansi([a, b])
      count = result.scan("\e[").size
      count.should be >= 3
    end
  end
end

describe Smith::UI::Span do
  it "reports its own display width" do
    Span.new("你好").width.should eq(4)
  end
end
