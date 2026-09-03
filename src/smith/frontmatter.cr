module Smith
  # The `---`-delimited header that skills and agent definitions both use.
  #
  # Deliberately not YAML: a line is `key: value`, values are flat strings, and
  # lists are comma-separated. That covers everything either format needs, and
  # keeps a malformed header from being able to fail a run.
  module Frontmatter
    HEADER = /\A---\s*\n(.*?)\n---\s*\n?(.*)\z/m
    # The opening delimiter alone, which is what separates "the author meant to
    # write a header" from "this file simply has none".
    OPENING = /\A---[ \t]*\r?\n/

    struct Document
      getter fields : Hash(String, String)
      getter body : String

      # True when a `---` block was opened but yielded no fields: it is never
      # closed, or no line in it is `key: value`. Either way everything declared
      # there is read as prose, silently — which is what makes it worth
      # reporting rather than merely tolerating.
      getter? malformed : Bool

      def initialize(@fields : Hash(String, String), @body : String, @malformed : Bool = false)
      end

      def [](key : String) : String?
        value = @fields[key]?
        return nil if value.nil? || value.empty?

        value
      end

      def empty? : Bool
        @fields.empty?
      end

      # nil when the key is absent, so "not configured" stays distinguishable
      # from "configured as empty".
      def list(key : String) : Array(String)?
        value = @fields[key]?
        return nil if value.nil?

        value.split(',').map(&.strip).reject(&.empty?)
      end
    end

    def self.parse(content : String) : Document
      fields = Hash(String, String).new

      match = content.match(HEADER)
      return Document.new(fields, content, malformed: OPENING.matches?(content)) if match.nil?

      match[1].each_line do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.starts_with?("#")

        key, _, value = stripped.partition(":")
        next if value.empty? && !stripped.includes?(":")

        fields[key.strip] = unquote(value.strip)
      end

      Document.new(fields, match[2], malformed: fields.empty?)
    end

    private def self.unquote(value : String) : String
      return value[1..-2] if value.size >= 2 && (value.starts_with?('"') && value.ends_with?('"'))
      return value[1..-2] if value.size >= 2 && (value.starts_with?('\'') && value.ends_with?('\''))

      value
    end
  end
end
