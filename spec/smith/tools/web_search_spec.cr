require "../../spec_helper"
require "http/server"
require "../../../src/smith/tools/web_search"

private BRAVE_BODY = <<-JSON
  {"web": {"results": [
    {"title": "Crystal Docs", "url": "https://crystal-lang.org/api", "description": "The API docs."},
    {"title": "No URL here"}
  ]}}
  JSON

private TAVILY_BODY = <<-JSON
  {"results": [
    {"title": "Tavily hit", "url": "https://example.com/a", "content": "snippet a"}
  ]}
  JSON

private SEARXNG_BODY = <<-JSON
  {"results": [
    {"title": "First", "url": "https://example.com/1", "content": "one"},
    {"title": "Second", "url": "https://docs.example.org/2", "content": "two"}
  ]}
  JSON

describe "search adapters" do
  it "parses a Brave response and skips an entry with no url" do
    results = Smith::Web::BraveSearch.new("key").parse(BRAVE_BODY)

    results.size.should eq(1)
    results.first.title.should eq("Crystal Docs")
    results.first.url.should eq("https://crystal-lang.org/api")
    results.first.snippet.should eq("The API docs.")
  end

  it "parses a Tavily response" do
    results = Smith::Web::TavilySearch.new("key").parse(TAVILY_BODY)

    results.first.url.should eq("https://example.com/a")
    results.first.snippet.should eq("snippet a")
  end

  it "parses a SearxNG response" do
    Smith::Web::SearxngSearch.new("http://localhost:8888").parse(SEARXNG_BODY).size.should eq(2)
  end

  it "survives a response shaped differently than expected" do
    Smith::Web::BraveSearch.new("key").parse(%({"unexpected": true})).should be_empty
  end

  it "says which key is missing rather than failing obscurely" do
    expect_raises(Smith::Web::SearchProvider::MissingKey, /BRAVE_API_KEY/) do
      Smith::Web::BraveSearch.new(nil).search("x", 5)
    end

    expect_raises(Smith::Web::SearchProvider::MissingKey, /TAVILY_API_KEY/) do
      Smith::Web::TavilySearch.new("").search("x", 5)
    end
  end
end

describe "building a provider" do
  it "returns nothing for none or an unknown name" do
    Smith::Web::SearchProvider.build("none").should be_nil
    Smith::Web::SearchProvider.build("nonsense").should be_nil
  end

  it "builds the named ones" do
    Smith::Web::SearchProvider.build("searxng").not_nil!.name.should eq("searxng")
    Smith::Web::SearchProvider.build("brave").not_nil!.name.should eq("brave")
  end
end

# SearxNG's host is configurable, which lets the whole tool run end to end
# against a local server without touching the network.
private def with_searxng(body : String, &)
  server = HTTP::Server.new do |context|
    context.response.content_type = "application/json"
    context.response.print body
  end
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield

  begin
    yield Smith::Tools::WebSearch.new(Smith::Web::SearxngSearch.new("http://127.0.0.1:#{address.port}"))
  ensure
    server.close
  end
end

describe Smith::Tools::WebSearch do
  it "lists title, url and snippet per hit" do
    with_searxng(SEARXNG_BODY) do |tool|
      result = tool.run(JSON.parse(%({"query": "crystal http"})))

      result.should contain("First")
      result.should contain("https://example.com/1")
      result.should contain("one")
      result.should contain("Second")
    end
  end

  it "marks the results as untrusted" do
    with_searxng(SEARXNG_BODY) do |tool|
      tool.run(JSON.parse(%({"query": "x"}))).should contain("Untrusted search results")
    end
  end

  it "keeps only the allowed domains, subdomains included" do
    with_searxng(SEARXNG_BODY) do |tool|
      result = tool.run(JSON.parse(%({"query": "x", "allowed_domains": ["example.org"]})))

      result.should contain("docs.example.org")
      result.should_not contain("https://example.com/1")
    end
  end

  it "says so when nothing matched" do
    with_searxng(%({"results": []})) do |tool|
      tool.run(JSON.parse(%({"query": "nothing"}))).should contain("No results")
    end
  end

  it "requires a query" do
    with_searxng(SEARXNG_BODY) do |tool|
      tool.run(JSON.parse("{}")).should start_with("Error:")
    end
  end

  it "reports a failing search as a tool error" do
    tool = Smith::Tools::WebSearch.new(Smith::Web::SearxngSearch.new("http://127.0.0.1:1"))

    tool.run(JSON.parse(%({"query": "x"}))).should start_with("Error:")
  end

  it "puts today's date in its description, so 'latest' means today" do
    with_searxng(SEARXNG_BODY) do |tool|
      tool.description.should contain(Time.local.to_s("%Y-%m-%d"))
    end
  end

  it "is parallel-safe and mutates nothing" do
    with_searxng(SEARXNG_BODY) do |tool|
      tool.parallel?.should be_true
      tool.mutating?.should be_false
    end
  end
end
