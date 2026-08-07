require "../../spec_helper"
require "../../../src/smith/web/html_to_markdown"

private def convert(html : String) : String
  Smith::Web::HtmlToMarkdown.convert(html)
end

describe Smith::Web::HtmlToMarkdown do
  it "turns headings into hashes" do
    result = convert("<h1>Title</h1><h2>Section</h2><h3>Sub</h3>")

    result.should contain("# Title")
    result.should contain("## Section")
    result.should contain("### Sub")
  end

  it "turns list items into bullets" do
    result = convert("<ul><li>first</li><li>second</li></ul>")

    result.should contain("- first")
    result.should contain("- second")
  end

  it "numbers ordered lists" do
    result = convert("<ol><li>one</li><li>two</li></ol>")

    result.should contain("1. one")
    result.should contain("2. two")
  end

  it "keeps links with their target" do
    convert(%(<a href="https://example.com/docs">the docs</a>))
      .should contain("[the docs](https://example.com/docs)")
  end

  it "renders code inline and in blocks" do
    convert("<p>Use <code>Array#map</code> here.</p>").should contain("`Array#map`")

    block = convert("<pre><code>def foo\n  42\nend</code></pre>")
    block.should contain("```")
    block.should contain("def foo")
  end

  it "drops script and style content entirely" do
    result = convert(<<-HTML)
      <html><head><style>body { color: red; }</style></head>
      <body><script>alert('nope')</script><p>real text</p></body></html>
      HTML

    result.should contain("real text")
    result.should_not contain("alert")
    result.should_not contain("color: red")
  end

  it "drops chrome that carries no content" do
    result = convert("<nav><a href='/x'>Home</a></nav><main><p>content</p></main><footer>© 2026</footer>")

    result.should contain("content")
    result.should_not contain("Home")
    result.should_not contain("2026")
  end

  it "decodes the common entities" do
    convert("<p>a &amp; b &lt;tag&gt; &quot;quoted&quot; &#39;x&#39; &nbsp;end</p>")
      .should contain(%(a & b <tag> "quoted" 'x'))
  end

  it "separates block elements instead of running them together" do
    convert("<p>one</p><p>two</p>").should contain("one\n\ntwo")
  end

  it "does not pile up blank lines" do
    convert("<div><div><p>a</p></div></div><br><br><p>b</p>").should_not contain("\n\n\n")
  end

  it "survives unclosed and unknown tags" do
    result = convert("<p>text<span>more<custom-element>deep")

    result.should contain("text")
    result.should contain("more")
    result.should contain("deep")
  end

  it "returns nothing for markup with no text" do
    convert("<html><head><title>t</title></head><body></body></html>").strip.should be_empty
  end
end
