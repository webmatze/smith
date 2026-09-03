module Smith
  # The `---`-delimited header that skills and agent definitions both use.
  #
  # Deliberately not YAML: a line is `key: value`, values are flat strings, and
  # lists are comma-separated. That covers everything either format needs, and
  # keeps a malformed header from being able to fail a run.
  module Frontmatter
    HEADER = /\A---\s*\n(.*?)\n---\s*\n?(.*)\z/m
    # The opening delimiter alone, which is what separates "the author meant to
    # write a header" from "this file simply has none". Deliberately more
    # tolerant than HEADER: a byte-order mark (routine from Windows editors) or
    # a leading space in front of `---` defeats HEADER while leaving the author
    # certain they wrote a header, and that gap is the whole point of the flag.
    OPENING = /\A\x{FEFF}?[ \t]*---[ \t]*\r?\n/

    struct Document
      getter fields : Hash(String, String)
      getter body : String

      # True when a `---` block was opened but not read the way it was written:
      # it is never closed, nothing in it is `key: value`, or one of its lines
      # is not (a YAML list under a key, say). What such a line declared is
      # dropped silently, and the flag is the only trace of it.
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
      return Document.new(fields, content, malformed: opens_header?(content)) if match.nil?

      # A line this rule cannot read is dropped, and dropping it silently is how
      # `tools:` over a YAML list ends up meaning "no tools at all". Reported
      # rather than repaired on purpose: teaching this parser YAML lists is a
      # format change, and `---\ntools:\n---` already means "configured as
      # empty" (see `list`) — so a caller cannot tell a dropped list from a
      # deliberate one, and only a warning can.
      unreadable = false

      match[1].each_line do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.starts_with?("#")

        key, _, value = stripped.partition(":")
        if value.empty? && !stripped.includes?(":")
          unreadable = true
          next
        end

        fields[key.strip] = unquote(value.strip)
      end

      Document.new(fields, match[2], malformed: fields.empty? || unreadable)
    end

    # An opened block still has to look like a header, because a markdown file
    # may legitimately begin with a `---` thematic break. Only the run of lines
    # before the first blank one counts: prose further down that happens to
    # carry a colon must not be able to make a break look like a header.
    #
    # That cut costs accuracy in both directions, deliberately, and both are
    # worth knowing before touching this:
    #
    # * False positive — a break followed, with no blank line between, by prose
    #   in which *any* line carries a colon is read as a header. A body opening
    #   `---` then `See https://example.com for more.` trips on the `https:`.
    # * False negative — a header opened, a blank line, then fields, and never
    #   closed (`---\n\nname: x\n`) stops at that blank line and is not
    #   flagged, though it is as broken as the same file without the blank.
    #   It is still reported, but as "no description", which points at the
    #   symptom rather than the cause.
    #
    # Both are the price of not telling prose from fields, which this format
    # cannot do. The trade is the right way round: a false positive costs one
    # advisory line on a file that still loads in full, and the false negative
    # still warns, while the case this catches — a header nobody read — is a
    # skill that silently never does what it says.
    private def self.opens_header?(content : String) : Bool
      opening = OPENING.match(content)
      return false if opening.nil?

      content[opening.end..].each_line do |line|
        stripped = line.strip
        return false if stripped.empty?
        next if stripped.starts_with?("#")
        return true if stripped.includes?(":")
      end

      false
    end

    private def self.unquote(value : String) : String
      return value[1..-2] if value.size >= 2 && (value.starts_with?('"') && value.ends_with?('"'))
      return value[1..-2] if value.size >= 2 && (value.starts_with?('\'') && value.ends_with?('\''))

      value
    end
  end
end
