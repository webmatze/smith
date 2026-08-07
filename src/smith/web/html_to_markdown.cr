module Smith::Web
  # Turns a fetched page into something worth putting in a context window.
  #
  # Deliberately not a parser: Crystal has no established HTML-to-Markdown
  # shard, and a full one is not the goal here. Documentation pages — headings,
  # lists, links, code — come out readable, and that is the bar. Anything
  # relying on precise nesting or on tables will come out flattened.
  module HtmlToMarkdown
    # Everything inside these carries no content worth reading, so they go
    # before any other processing — script and style especially, whose bodies
    # would otherwise survive as text.
    DROPPED = %w[script style head nav footer aside noscript svg iframe template]

    ENTITIES = {
      "&nbsp;" => " ", "&amp;" => "&", "&lt;" => "<", "&gt;" => ">",
      "&quot;" => "\"", "&#39;" => "'", "&apos;" => "'", "&mdash;" => "—",
      "&ndash;" => "–", "&hellip;" => "…", "&copy;" => "©", "&reg;" => "®",
    }

    def self.convert(html : String) : String
      text = html
      text = drop_elements(text)
      text = convert_code(text)
      text = convert_links(text)
      text = convert_headings(text)
      text = convert_lists(text)
      text = convert_blocks(text)
      text = text.gsub(/<[^>]*>/, "")
      text = decode_entities(text)

      tidy(text)
    end

    private def self.drop_elements(html : String) : String
      DROPPED.reduce(html) do |acc, tag|
        acc.gsub(/<#{tag}\b[^>]*>.*?<\/#{tag}>/im, "").gsub(/<#{tag}\b[^>]*\/?>/im, "")
      end
    end

    private def self.convert_code(html : String) : String
      html
        .gsub(/<pre[^>]*>\s*<code[^>]*>(.*?)<\/code>\s*<\/pre>/im) { "\n\n```\n#{strip_tags($1)}\n```\n\n" }
        .gsub(/<pre[^>]*>(.*?)<\/pre>/im) { "\n\n```\n#{strip_tags($1)}\n```\n\n" }
        .gsub(/<code[^>]*>(.*?)<\/code>/im) { "`#{strip_tags($1)}`" }
    end

    private def self.convert_links(html : String) : String
      html.gsub(/<a\b[^>]*?href\s*=\s*["']([^"']*)["'][^>]*>(.*?)<\/a>/im) do
        label = strip_tags($2).strip
        href = $1.strip
        label.empty? ? href : "[#{label}](#{href})"
      end
    end

    private def self.convert_headings(html : String) : String
      html.gsub(/<h([1-6])[^>]*>(.*?)<\/h\1>/im) do
        "\n\n#{"#" * $1.to_i} #{strip_tags($2).strip}\n\n"
      end
    end

    private def self.convert_lists(html : String) : String
      # Ordered lists are numbered per list, so the counter restarts each time.
      html.gsub(/<ol[^>]*>(.*?)<\/ol>/im) do
        counter = 0
        "\n\n" + $1.gsub(/<li[^>]*>(.*?)<\/li>/im) do
          counter += 1
          "#{counter}. #{strip_tags($1).strip}\n"
        end + "\n"
      end.gsub(/<li[^>]*>(.*?)<\/li>/im) { "- #{strip_tags($1).strip}\n" }
    end

    private def self.convert_blocks(html : String) : String
      html
        .gsub(/<br\s*\/?>/i, "\n")
        .gsub(/<\/(p|div|section|article|main|tr|table|ul|ol|blockquote)>/i, "\n\n")
        .gsub(/<\/t[dh]>/i, " ")
    end

    private def self.strip_tags(html : String) : String
      html.gsub(/<[^>]*>/, "")
    end

    private def self.decode_entities(text : String) : String
      result = ENTITIES.reduce(text) { |acc, (entity, char)| acc.gsub(entity, char) }
      # Numeric references, decimal and hex.
      result = result.gsub(/&#(\d+);/) { $1.to_i?.try(&.chr) || "" }
      result.gsub(/&#x([0-9a-f]+);/i) { $1.to_i?(16).try(&.chr) || "" }
    end

    private def self.tidy(text : String) : String
      text.lines
        .map(&.rstrip)
        .join("\n")
        .gsub(/\n{3,}/, "\n\n")
        .strip
    end
  end
end
