require "http/client"
require "json"
require "uri"

module Smith::Web
  struct SearchResult
    getter title : String
    getter url : String
    getter snippet : String

    def initialize(@title : String, @url : String, @snippet : String)
    end
  end

  # An adapter interface for the same reason LLM::Provider is one: no binding
  # to a single vendor, and the specs can parse a captured response without
  # touching the network.
  #
  # Deliberately no scraping of Google/Bing/DDG HTML — it breaks their terms
  # and breaks again at every layout change.
  abstract class SearchProvider
    abstract def name : String
    abstract def search(query : String, limit : Int32) : Array(SearchResult)

    # nil when searching is switched off or unconfigured, so the tool simply is
    # not registered.
    def self.build(kind : String, searxng_host : String? = nil) : SearchProvider?
      case kind.downcase
      when "brave"   then BraveSearch.new(ENV["BRAVE_API_KEY"]?)
      when "tavily"  then TavilySearch.new(ENV["TAVILY_API_KEY"]?)
      when "searxng" then SearxngSearch.new(searxng_host || SearxngSearch::DEFAULT_HOST)
      end
    end

    # API keys stay env-only, the same rule the provider keys follow.
    class MissingKey < Exception
    end

    protected def get(uri : URI, headers : HTTP::Headers) : String
      client = HTTP::Client.new(uri)
      client.connect_timeout = 10.seconds
      client.read_timeout = 20.seconds

      begin
        response = client.get(uri.request_target, headers: headers)
        raise "search returned HTTP #{response.status_code}" unless response.status.success?
        response.body
      ensure
        client.close
      end
    end
  end

  class BraveSearch < SearchProvider
    ENDPOINT = "https://api.search.brave.com/res/v1/web/search"

    def initialize(@api_key : String?)
    end

    def name : String
      "brave"
    end

    def search(query : String, limit : Int32) : Array(SearchResult)
      key = @api_key
      raise MissingKey.new("BRAVE_API_KEY is not set") if key.nil? || key.empty?

      uri = URI.parse(ENDPOINT)
      uri.query = URI::Params.encode({"q" => query, "count" => limit.to_s})

      parse(get(uri, HTTP::Headers{"Accept" => "application/json", "X-Subscription-Token" => key}))
    end

    def parse(body : String) : Array(SearchResult)
      json = JSON.parse(body)
      results = json["web"]?.try(&.["results"]?).try(&.as_a?) || [] of JSON::Any

      results.compact_map do |item|
        url = item["url"]?.try(&.as_s?)
        next if url.nil?

        SearchResult.new(
          title: item["title"]?.try(&.as_s?) || url,
          url: url,
          snippet: item["description"]?.try(&.as_s?) || ""
        )
      end
    end
  end

  class TavilySearch < SearchProvider
    ENDPOINT = "https://api.tavily.com/search"

    def initialize(@api_key : String?)
    end

    def name : String
      "tavily"
    end

    def search(query : String, limit : Int32) : Array(SearchResult)
      key = @api_key
      raise MissingKey.new("TAVILY_API_KEY is not set") if key.nil? || key.empty?

      uri = URI.parse(ENDPOINT)
      client = HTTP::Client.new(uri)
      client.connect_timeout = 10.seconds
      client.read_timeout = 20.seconds

      begin
        payload = {"api_key" => key, "query" => query, "max_results" => limit}.to_json
        response = client.post(uri.request_target, headers: HTTP::Headers{"Content-Type" => "application/json"}, body: payload)
        raise "search returned HTTP #{response.status_code}" unless response.status.success?
        parse(response.body)
      ensure
        client.close
      end
    end

    def parse(body : String) : Array(SearchResult)
      results = JSON.parse(body)["results"]?.try(&.as_a?) || [] of JSON::Any

      results.compact_map do |item|
        url = item["url"]?.try(&.as_s?)
        next if url.nil?

        SearchResult.new(
          title: item["title"]?.try(&.as_s?) || url,
          url: url,
          snippet: item["content"]?.try(&.as_s?) || ""
        )
      end
    end
  end

  # Self-hosted, no key, and the one that fits the local-first stance best.
  class SearxngSearch < SearchProvider
    DEFAULT_HOST = "http://localhost:8888"

    def initialize(@host : String)
    end

    def name : String
      "searxng"
    end

    def search(query : String, limit : Int32) : Array(SearchResult)
      uri = URI.parse("#{@host.chomp("/")}/search")
      uri.query = URI::Params.encode({"q" => query, "format" => "json"})

      parse(get(uri, HTTP::Headers{"Accept" => "application/json"})).first(limit)
    end

    def parse(body : String) : Array(SearchResult)
      results = JSON.parse(body)["results"]?.try(&.as_a?) || [] of JSON::Any

      results.compact_map do |item|
        url = item["url"]?.try(&.as_s?)
        next if url.nil?

        SearchResult.new(
          title: item["title"]?.try(&.as_s?) || url,
          url: url,
          snippet: item["content"]?.try(&.as_s?) || ""
        )
      end
    end
  end
end
