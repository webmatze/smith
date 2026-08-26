require "./file_kind"
require "./media"
require "./llm/types"
require "./tools/permissions"

module Smith
  # `@path` in a prompt pulls the file into the first request.
  #
  # Without it the model spends a full provider roundtrip on `read_file` to
  # reach a path the user already named — and guesses at paths when it gets
  # them wrong. The `@path` stays in the text so the sentence still reads;
  # the content is appended below it.
  #
  # Kept out of Skills::Catalog on purpose: expanding skills and reading files
  # are different jobs, and `expand_prompt` is already dense enough.
  module Mentions
    DEFAULT_MAX_LINES       = 2000
    DEFAULT_MAX_TOTAL_BYTES = 256 * 1024

    # `@` only counts at the start of a word, which is what keeps
    # foo@bar.com from being read as a mention. Either a quoted path — for
    # spaces — or a run of non-whitespace.
    PATTERN = /(^|\s)@(?:"([^"]+)"|([^\s]+))/m

    # A path is rarely the last thing in a sentence, so trailing sentence
    # punctuation is not part of it. A trailing slash is: it is what marks a
    # directory listing.
    TRAILING_PUNCTUATION = ".,;:!?)]}"

    struct Settings
      getter max_lines : Int32
      getter max_total_bytes : Int32
      getter? allow_outside : Bool

      # Its own budget, not a share of max_total_bytes: that one counts what
      # is inlined as text, and a limit meant for source files says nothing
      # about what an image is worth.
      getter max_media_bytes : Int32

      def initialize(
        @max_lines : Int32 = DEFAULT_MAX_LINES,
        @max_total_bytes : Int32 = DEFAULT_MAX_TOTAL_BYTES,
        @allow_outside : Bool = false,
        @max_media_bytes : Int32 = Media::DEFAULT_MAX_BYTES,
      )
      end
    end

    # A file or directory that made it into the prompt. `path` is as written,
    # so it matches what the user typed.
    struct Embedded
      getter path : String
      getter lines : Int32
      getter? truncated : Bool

      # Set for an attachment, nil for text and directories. `lines` says
      # nothing about a PNG, so the renderers need something else to print.
      getter media_type : String?
      getter bytes : Int32?

      def initialize(
        @path : String,
        @lines : Int32,
        @truncated : Bool = false,
        @media_type : String? = nil,
        @bytes : Int32? = nil,
      )
      end

      def media? : Bool
        !@media_type.nil?
      end
    end

    # A mention that was left alone, and why. Never fatal: the user may well
    # have meant a literal `@`.
    struct Skip
      getter path : String
      getter reason : String

      def initialize(@path : String, @reason : String)
      end
    end

    struct Result
      getter text : String
      getter files : Array(Embedded)
      getter skipped : Array(Skip)

      # Images and PDFs, as blocks to hang beside the text. They cannot go
      # *into* it — that is the whole difference between a mention of a source
      # file and a mention of a screenshot.
      getter attachments : Array(LLM::ContentBlock)

      def initialize(
        @text : String,
        @files : Array(Embedded),
        @skipped : Array(Skip),
        @attachments : Array(LLM::ContentBlock) = Array(LLM::ContentBlock).new,
      )
      end

      def any? : Bool
        !@files.empty? || !@skipped.empty?
      end
    end

    def self.expand(text : String, project_dir : String, settings : Settings = Settings.new) : Result
      files = Array(Embedded).new
      skipped = Array(Skip).new
      attachments = Array(String).new
      media = Array(LLM::ContentBlock).new
      seen = Set(String).new
      spent = 0

      # The project dir is resolved the same way candidate paths are. A
      # symlinked project — /tmp on macOS — would otherwise make every
      # relative mention look like an escape.
      root = Tools::Paths.normalize(project_dir, project_dir)

      each_mention(text) do |written|
        next if seen.includes?(written)
        seen << written

        resolved = resolve(written, project_dir)

        unless settings.allow_outside? || inside?(resolved, root)
          skipped << Skip.new(written, "outside the project (set [mentions] allow_outside to permit it)")
          next
        end

        if Dir.exists?(resolved)
          attachments << render_directory(written, resolved)
          files << Embedded.new(written, 0)
          next
        end

        unless File.exists?(resolved)
          skipped << Skip.new(written, "does not exist")
          next
        end

        # Before the binary check, not after: an image *is* binary, and the
        # signature is what tells the two apart. A `.png` holding text falls
        # through to the text path below and is inlined as what it is.
        if Media.detect_file(resolved)
          size = File.size(resolved)

          if size > settings.max_media_bytes
            skipped << Skip.new(
              written,
              "#{Media.human_size(size.to_i32)} is over the #{Media.human_size(settings.max_media_bytes)} " \
              "attachment limit ([media] max_bytes)"
            )
            next
          end

          attachment = Media.read(resolved)
          if attachment.nil?
            skipped << Skip.new(written, "could not be read")
            next
          end

          media << if attachment.image?
            LLM::ContentBlock.image(attachment.media_type, attachment.data, written)
          else
            LLM::ContentBlock.document(attachment.media_type, attachment.data, written)
          end
          files << Embedded.new(written, 0, media_type: attachment.media_type, bytes: attachment.bytes)
          next
        end

        if FileKind.binary?(resolved)
          skipped << Skip.new(written, "looks binary")
          next
        end

        body, lines, truncated = read_text(resolved, settings.max_lines)
        attachment = render_file(written, body, lines, truncated)

        if spent + attachment.bytesize > settings.max_total_bytes
          skipped << Skip.new(written, "not inlined, budget exceeded; use read_file")
          next
        end

        spent += attachment.bytesize
        attachments << attachment
        files << Embedded.new(written, lines, truncated)
      end

      Result.new(join(text, attachments), files, skipped, media)
    end

    # Yields every mention exactly as it was written, quotes stripped.
    private def self.each_mention(text : String, &)
      text.scan(PATTERN) do |match|
        quoted = match[2]?
        bare = match[3]?

        if quoted
          yield quoted unless quoted.empty?
        elsif bare
          trimmed = bare.rstrip(TRAILING_PUNCTUATION)
          yield trimmed unless trimmed.empty?
        end
      end
    end

    private def self.resolve(written : String, project_dir : String) : String
      # home: true is what makes @~/notes.md a path rather than a directory
      # literally named "~".
      absolute = File.expand_path(written, project_dir, home: true)
      Tools::Paths.normalize(absolute, project_dir)
    end

    private def self.inside?(path : String, root : String) : Bool
      path == root || path.starts_with?("#{root}#{File::SEPARATOR}")
    end

    private def self.read_text(path : String, max_lines : Int32) : {String, Int32, Bool}
      lines = File.read_lines(path)
      total = lines.size

      if total > max_lines
        {lines.first(max_lines).join("\n"), total, true}
      else
        {lines.join("\n"), total, false}
      end
    rescue ex : File::Error | IO::Error
      {"(could not be read: #{ex.message})", 0, false}
    end

    private def self.render_file(written : String, body : String, lines : Int32, truncated : Bool) : String
      # Deliberately the same shape as the skill attachment in skills.cr, so a
      # prompt with both in it reads as one document.
      header = if truncated
                 "--- File: #{written} (#{lines} lines, truncated) ---"
               else
                 "--- File: #{written} (#{lines} lines) ---"
               end

      String.build do |str|
        str.puts header
        str.puts body
        str.puts "... [truncated after the first lines]" if truncated
      end
    end

    # A directory is listed, never walked: inlining a tree is how a prompt
    # silently becomes a megabyte.
    private def self.render_directory(written : String, resolved : String) : String
      entries = Dir.children(resolved).sort!
      label = written.ends_with?('/') ? written : "#{written}/"

      String.build do |str|
        str.puts "--- Directory: #{label} (#{entries.size} entries) ---"
        entries.each { |entry| str.puts entry }
      end
    end

    private def self.join(text : String, attachments : Array(String)) : String
      return text if attachments.empty?

      String.build do |str|
        str.puts text
        attachments.each do |attachment|
          str.puts ""
          str.print attachment
        end
      end.rstrip
    end
  end
end
