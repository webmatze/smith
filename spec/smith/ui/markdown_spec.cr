require "../../spec_helper"
require "../../../src/smith/ui/markdown"

include Smith::UI

private def plain_lines(lines : Array(Smith::UI::StyledLine)) : Array(String)
  lines.map { |l| Smith::UI::LineUtil.plain(l) }
end

describe Smith::UI::Markdown do
  describe ".render" do
    it "renders plain paragraphs" do
      lines = Markdown.render("hello world", 80)
      _lines = plain_lines(lines)
      _lines.should eq(["hello world"])
    end

    it "renders headings and drops the hashes" do
      lines = Markdown.render("## Title here", 80)
      _lines = plain_lines(lines)
      _lines.should eq(["Title here"])
      lines[0][0].style.bold?.should be_true
    end

    it "does not treat # inside a word as a heading" do
      lines = Markdown.render("#hashtag", 80)
      _lines = plain_lines(lines)
      _lines.should eq(["#hashtag"])
    end

    it "renders bullet lists" do
      lines = Markdown.render("- one\n- two", 80)
      _lines = plain_lines(lines)
      _lines.should eq(["• one", "• two"])
    end

    it "renders task-list checkboxes" do
      lines = Markdown.render("- [x] done\n- [ ] open", 80)
      plain_lines(lines)[0].should start_with("☑")
      plain_lines(lines)[1].should start_with("☐")
    end

    it "renders numbered lists" do
      lines = Markdown.render("1. first\n2. second", 80)
      plain_lines(lines)[0].should start_with("1. first")
      plain_lines(lines)[1].should start_with("2. second")
    end

    it "renders fenced code blocks" do
      lines = Markdown.render("```crystal\nputs 1\n```", 80)
      _lines = plain_lines(lines)
      _lines.should eq(["``` crystal", "puts 1", "```"])
    end

    it "keeps an unterminated fence open — streaming edge" do
      lines = Markdown.render("```\npartial", 80)
      _lines = plain_lines(lines)
      _lines.should eq(["```", "partial"])
    end

    it "renders blockquotes with a bar" do
      lines = Markdown.render("> quoted", 80)
      _lines = plain_lines(lines)
      _lines.should eq(["▐ quoted"])
    end

    it "renders horizontal rules" do
      lines = Markdown.render("---", 80)
      plain_lines(lines)[0].should contain("─")
    end

    it "wraps long lines to the width" do
      lines = Markdown.render("the quick brown fox jumps over", 10)
      _lines = plain_lines(lines)
      _lines.each { |l| l.size.should be <= 10 }
    end
  end

  describe ".inline" do
    it "parses bold" do
      spans = Markdown.inline("a **b** c")
      bold = spans.find { |s| s.style.bold? }
      bold.not_nil!.text.should eq("b")
    end

    it "parses italics" do
      spans = Markdown.inline("a *b* c")
      italic = spans.find { |s| s.style.italic? }
      italic.not_nil!.text.should eq("b")
    end

    it "parses inline code" do
      spans = Markdown.inline("run `make test`")
      code = spans.find { |s| s.style.fg == Palette::CODE }
      code.not_nil!.text.should eq("make test")
    end

    it "parses strikethrough" do
      spans = Markdown.inline("~~gone~~")
      spans.any? { |s| s.style.dim? && s.text == "gone" }.should be_true
    end

    it "shows link text and drops the url" do
      spans = Markdown.inline("see [docs](https://example.com)")
      link = spans.find { |s| s.style.underline? }
      link.not_nil!.text.should eq("docs")
    end

    it "leaves a lone asterisk literal" do
      spans = Markdown.inline("a * b")
      LineUtil.plain(spans).should eq("a * b")
    end

    it "layers inline styles on top of a base style" do
      base = Style.new(fg: Color.ansi256(5))
      spans = Markdown.inline("**b**", base)
      bold = spans.find { |s| s.style.bold? }
      bold.not_nil!.style.fg.should eq(Color.ansi256(5))
    end
  end
end
