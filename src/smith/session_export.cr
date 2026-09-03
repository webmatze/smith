require "json"
require "./llm/types"
require "./pricing"
require "./session"
require "./transcript_log"

module Smith
  # Takes a finished run out of `~/.smith` — as Markdown to read, paste into an
  # issue or attach to a bug report, or as the structured log for a tool.
  #
  # Reads only. Nothing here builds a provider, needs an API key or touches the
  # network: an export is a view over files that are already on disk.
  module SessionExport
    # Tool arguments, tool results and thinking are cut to this in Markdown.
    # A run that spent 200 KB on `crystal spec` output is not readable at full
    # length, and `--json` is right there for anyone who wants all of it.
    ABBREVIATED_CHARS = 800

    # The offset is part of the timestamp. An export is read somewhere other
    # than where it was made, and the JSON says UTC.
    TIME_FORMAT = "%Y-%m-%d %H:%M:%S %:z"

    # Which of the two records the messages came from. They are not versions of
    # one another: compaction shortens the session file, while a transcript log
    # that could not be written is abandoned mid-run and ends up a prefix. So
    # the export names its source rather than presenting either as *the* run.
    enum Source
      Transcript
      Session

      def label : String
        transcript? ? "transcript.jsonl" : "session.json"
      end
    end

    class Document
      getter id : String
      getter name : String?
      getter provider : String?
      getter model : String?
      getter created_at : Time?
      getter updated_at : Time?
      getter cwd : String?
      getter usage : LLM::Usage?
      getter cost : Float64?
      getter todos : Array(TodoList::Item)
      getter messages : Array(LLM::Message)
      getter source : Source

      # How long each record was, so a disagreement between them is visible
      # instead of hidden behind whichever one was picked. nil means that
      # record is not there at all.
      getter transcript_count : Int32?
      getter session_count : Int32?

      # Lines of the transcript that could not be parsed. Counted rather than
      # dropped: without it a record that lost a line looks exactly like an
      # intact one.
      getter transcript_skipped : Int32

      # Damage found on the way in. Reported beside the export, never in it:
      # stdout stays the document so it can be piped.
      getter warnings : Array(String)

      def initialize(
        @id : String,
        @messages : Array(LLM::Message),
        @source : Source,
        @name : String? = nil,
        @provider : String? = nil,
        @model : String? = nil,
        @created_at : Time? = nil,
        @updated_at : Time? = nil,
        @cwd : String? = nil,
        @usage : LLM::Usage? = nil,
        @cost : Float64? = nil,
        @todos : Array(TodoList::Item) = Array(TodoList::Item).new,
        @transcript_count : Int32? = nil,
        @transcript_skipped : Int32 = 0,
        @session_count : Int32? = nil,
        @warnings : Array(String) = Array(String).new,
      )
      end

      # What the user would type to get this session back.
      def reference : String
        @name || @id
      end

      def to_markdown : String
        String.build do |md|
          md << "# " << SessionExport.sanitize(reference) << "\n\n"
          header(md)
          todo_section(md)

          md << "## Transcript\n"
          if @messages.empty?
            md << "\n_This session has no messages._\n"
          else
            @messages.each_with_index { |message, index| SessionExport.render_message(md, message, index + 1) }
          end
        end
      end

      # The whole log, unabbreviated. `data` never reaches it: the base64 of an
      # attachment is `JSON::Field(ignore: true)`, so what serializes is the
      # media type and the digest that finds the bytes in the session directory.
      def to_json_document : String
        # Scrubbed as a whole rather than field by field: a message carries
        # whatever bytes a tool produced, and one invalid UTF-8 sequence
        # anywhere makes the document invalid JSON for every reader. The
        # delimiters are ASCII, so replacing bad bytes inside the strings
        # cannot disturb the structure — and JSON already escapes the control
        # characters the Markdown path has to strip by hand.
        build_json.scrub
      end

      private def build_json : String
        JSON.build(indent: "  ") do |json|
          json.object do
            json.field "id", @id
            json.field "name", @name
            json.field "provider", @provider
            json.field "model", @model
            json.field "created_at", @created_at.try(&.to_rfc3339)
            json.field "updated_at", @updated_at.try(&.to_rfc3339)
            json.field "cwd", @cwd
            json.field "source", @source.label
            json.field "message_count", @messages.size
            # null, not zeroes, when nothing was recorded — zero-as-unknown
            # reads as "this run was free", which is the Pricing rule's whole
            # point. Same for the cost below.
            json.field("usage") { (usage = @usage) ? usage.to_json(json) : json.null }
            json.field "cost_usd", @cost
            json.field("todos") { @todos.to_json(json) }
            json.field("messages") { @messages.to_json(json) }
          end
        end
      end

      private def header(md : String::Builder) : Nil
        md << "- **Session:** `" << SessionExport.sanitize(@id) << "`\n"
        md << "- **Provider / model:** " << SessionExport.sanitize(@provider || "unknown") <<
          " / " << SessionExport.sanitize(@model || "unknown") << "\n"
        # With the offset: an export is read somewhere else than it was made,
        # and a bare wall-clock time next to the UTC one in the JSON reads as
        # two different instants.
        @created_at.try { |time| md << "- **Created:** " << time.to_s(TIME_FORMAT) << "\n" }
        @updated_at.try { |time| md << "- **Updated:** " << time.to_s(TIME_FORMAT) << "\n" }
        @cwd.try { |dir| md << "- **Working directory:** `" << SessionExport.sanitize(dir) << "`\n" }

        if usage = @usage
          md << "- **Tokens:** " << usage.prompt_tokens << " prompt, " << usage.completion_tokens <<
            " completion, " << usage.cached_tokens << " cache\n"
        end
        md << "- **Cost:** " << Pricing.format(@cost) << "\n"
        md << "- **Exported from:** `" << @source.label << "` (" << source_note << ")\n"
        md << "\n_Tool arguments, tool results and thinking are abbreviated to " << ABBREVIATED_CHARS <<
          " characters; `--json` exports the log in full._\n\n"
      end

      # Both counts, always, so a shorter record is never passed off as the
      # run — and the lines that could not be read, because a record that lost
      # one otherwise looks exactly like an intact one.
      private def source_note : String
        parts = [@source.transcript? ? "the untouched record" : "the working history, after compaction"]
        parts << "#{@messages.size} message(s)"
        parts << "#{@transcript_skipped} unreadable line(s) skipped" if @transcript_skipped > 0

        other = @source.transcript? ? @session_count : @transcript_count
        other_label = @source.transcript? ? "session file" : "raw transcript"
        parts << (other.nil? ? "no #{other_label}" : "#{other_label}: #{other}")

        parts.join("; ")
      end

      private def todo_section(md : String::Builder) : Nil
        return if @todos.empty?

        md << "## Todos\n\n"
        @todos.each do |item|
          mark = item.status.completed? ? "x" : " "
          suffix = item.status.in_progress? ? " _(in progress)_" : ""
          md << "- [" << mark << "] " << SessionExport.sanitize(item.content) << suffix << "\n"
        end
        md << "\n"
      end
    end

    # Builds the export for whatever the user typed — a name or an id, resolved
    # by the same helper `resume` and `sessions delete` use.
    #
    # Every kind of damage short of "there is nothing here" degrades into a
    # warning: a session file that will not parse falls back to the raw
    # transcript, an unreadable transcript line is skipped by the log itself,
    # and a corrupt index costs the export nothing but the name lookup.
    def self.build(store : Session::Store, reference : String, overrides : Pricing::Overrides? = nil) : Document
      id = resolve(store, reference)
      warnings = Array(String).new

      data = load_session(store, id, warnings)
      recorded, skipped_lines = load_transcript(store, id, warnings)

      if skipped_lines > 0
        warnings << "#{skipped_lines} line(s) of the transcript could not be read and were skipped; the record is incomplete."
      end

      if data.nil? && (recorded.nil? || recorded.empty?)
        raise ArgumentError.new(
          "Session '#{reference}' has nothing to export: no readable session file and no transcript under #{store.session_dir(id)}."
        )
      end

      # The transcript wins when it has anything, because it is the record from
      # before compaction touched it. It can still be the shorter of the two —
      # a log that could not be written is given up on mid-run — and that is
      # what the warning below is for.
      source, messages = if recorded && !recorded.empty?
                           {Source::Transcript, recorded}
                         else
                           {Source::Session, data.try(&.messages) || Array(LLM::Message).new}
                         end

      warnings << "The transcript beside #{id} holds no readable message; exporting the session file instead." if recorded && recorded.empty?

      session_count = data.try(&.messages.size)
      if source.transcript? && session_count && session_count > messages.size
        warnings << "The raw transcript holds fewer messages (#{messages.size}) than the session file (#{session_count}); the record was cut short while the session ran."
      end

      entry = index_entry(store, id, warnings)
      provider = data.try(&.provider) || entry.try(&.provider)
      model = data.try(&.model) || entry.try(&.model)
      usage = data.try(&.usage) || entry.try(&.usage)

      Document.new(
        id: id,
        messages: messages,
        source: source,
        name: data.try(&.name) || entry.try(&.name),
        provider: provider,
        model: model,
        created_at: data.try(&.created_at) || entry.try(&.created_at),
        updated_at: data.try(&.updated_at) || entry.try(&.updated_at),
        cwd: data.try(&.cwd),
        usage: usage,
        cost: cost_of(usage, provider, model, overrides),
        todos: data.try(&.todos) || Array(TodoList::Item).new,
        transcript_count: recorded.try(&.size),
        transcript_skipped: skipped_lines,
        session_count: session_count,
        warnings: warnings
      )
    end

    # The store resolves against the index and against `session.json`. A
    # directory that has lost both but still holds its raw transcript is
    # exactly the case an export is for, so an id naming one is accepted —
    # after the store has had its say, so names keep resolving the usual way.
    #
    # `NotFound` only: an ambiguous name and a reference that is a path are
    # both refusals the user has to see, not gaps to paper over.
    private def self.resolve(store : Session::Store, reference : String) : String
      store.resolve_id(reference)
    rescue ex : Session::NotFound
      candidate = reference.strip
      raise ex unless TranscriptLog.new(store.session_dir(candidate)).exists?

      candidate
    end

    private def self.cost_of(usage : LLM::Usage?, provider : String?, model : String?, overrides : Pricing::Overrides?) : Float64?
      return nil if usage.nil? || provider.nil? || model.nil?

      Pricing.estimate(usage, provider, model, overrides)
    end

    private def self.load_session(store : Session::Store, id : String, warnings : Array(String)) : Session::Data?
      store.load(id)
    rescue ArgumentError
      warnings << "No session file for #{id}; exporting what the raw transcript recorded."
      nil
    rescue ex
      warnings << "The session file of #{id} could not be read (#{ex.message}); exporting what the raw transcript recorded."
      nil
    end

    # A nil message array means there is no transcript log at all, which is
    # different from one that is there and empty.
    private def self.load_transcript(store : Session::Store, id : String, warnings : Array(String)) : {Array(LLM::Message)?, Int32}
      log = TranscriptLog.new(store.session_dir(id))
      return {nil, 0} unless log.exists?

      log.read
    rescue ex
      warnings << "The transcript at #{store.session_dir(id)} could not be read (#{ex.message})."
      {nil, 0}
    end

    # A damaged entry costs its own session and no other, so the export finds
    # what it needs whenever the entry it wants is intact — and everything the
    # index would have said is in the session file too.
    private def self.index_entry(store : Session::Store, id : String, warnings : Array(String)) : Session::IndexEntry?
      entries, damage = store.read_index
      damage.each { |problem| warnings << "The session index is damaged: #{problem}." }

      entries.find { |e| e.id == id }
    end

    def self.render_message(md : String::Builder, message : LLM::Message, position : Int32) : Nil
      md << "\n### " << position << " · " << role_label(message.role)
      # A user message smith wrote itself, not one the user typed.
      md << " _(continuation by smith)_" if message.synthetic?
      md << "\n"

      message.content.each { |block| render_block(md, block) }
    end

    private def self.role_label(role : LLM::Role) : String
      case role
      when .user?      then "User"
      when .assistant? then "Assistant"
      when .tool?      then "Tool results"
      else                  "System"
      end
    end

    private def self.render_block(md : String::Builder, block : LLM::ContentBlock) : Nil
      case block.type
      when .text?
        text = sanitize(block.text || "").strip
        md << "\n" << close_open_fence(text) << "\n" unless text.empty?
      when .thinking?
        md << "\n**Thinking**\n\n" << quote(abbreviate(sanitize(block.text || "")))
      when .redacted_thinking?
        md << "\n_Redacted thinking (" << (block.text.try(&.size) || 0) << " encrypted characters, not shown)._\n"
      when .tool_use?
        render_tool_use(md, block)
      when .tool_result?
        render_tool_result(md, block)
      when .image?, .document?
        render_media(md, block)
      end
    end

    private def self.render_tool_use(md : String::Builder, block : LLM::ContentBlock) : Nil
      md << "\n**Tool call: `" << sanitize(block.tool_name || "unknown") << "`**"
      block.tool_call_id.try { |id| md << " (`" << sanitize(id) << "`)" }
      md << "\n\n"

      args = block.tool_args.try(&.to_json)
      if args.nil? || args.empty?
        md << "_No arguments._\n"
      else
        fenced(md, abbreviate(sanitize(args)), "json")
      end
    end

    private def self.render_tool_result(md : String::Builder, block : LLM::ContentBlock) : Nil
      md << "\n**Tool result**"
      block.tool_call_id.try { |id| md << " (`" << sanitize(id) << "`)" }
      md << " — error" if block.is_error
      md << "\n\n"

      text = block.text
      if text.nil? || text.empty?
        md << "_Empty result._\n"
      else
        fenced(md, abbreviate(sanitize(text)))
      end
    end

    # Never the bytes. `Store#load` puts the base64 of an attachment back into
    # the block it came from, and a screenshot inlined into a Markdown export
    # is megabytes of noise where one line of description belongs.
    private def self.render_media(md : String::Builder, block : LLM::ContentBlock) : Nil
      kind = block.type.document? ? "Document" : "Image"
      md << "\n_[" << kind << ": " << sanitize(block.media_label)
      block.media_type.try { |type| md << " (" << sanitize(type) << ")" if type != block.media_label }
      block.media_ref.try { |ref| md << ", stored as `" << sanitize(ref[0, Math.min(12, ref.size)]) << "`" }
      md << "]_\n"
    end

    # What a transcript is allowed to put into the document.
    #
    # Tool output is bytes from someone else's program. It can be invalid
    # UTF-8 — a `bash` result carrying Latin-1 or a stray binary byte — which
    # would make the export unreadable to anything that expects text and, on
    # the JSON path, not even valid JSON. And it can carry NUL, BEL or raw
    # ANSI escapes, which turn a `cat` of the file into a terminal effect and
    # make `grep` treat a Markdown file as binary.
    #
    # `\n` and `\t` are the structure of the output and stay; `\r` is a
    # terminal effect in captured output and goes; everything else in the
    # control range becomes the replacement character, which says a byte was
    # there without acting on the terminal.
    def self.sanitize(text : String) : String
      scrubbed = text.scrub
      return scrubbed unless scrubbed.each_char.any? { |char| strip?(char) }

      String.build(scrubbed.bytesize) do |io|
        scrubbed.each_char do |char|
          next if char == '\r'
          io << (strip?(char) ? '�' : char)
        end
      end
    end

    private def self.strip?(char : Char) : Bool
      return false if char == '\n' || char == '\t'

      char.control?
    end

    # A code fence the message never closed — an assistant turn cut off at
    # max_tokens is the everyday way to get one — would swallow every heading,
    # tool call and result after it. Closing it costs one line; leaving it open
    # costs the rest of the document.
    #
    # Tracked the way CommonMark reads fences rather than counted: a shorter
    # run of backticks *inside* a longer fence is content, not a second fence,
    # and a parity count would "close" a document that was never open.
    private def self.close_open_fence(text : String) : String
      open : String? = nil

      text.each_line do |line|
        match = line.match(/\A {0,3}(`{3,})(.*)\z/)
        next if match.nil?

        marker, rest = match[1], match[2]

        if open.nil?
          # An opening fence may carry an info string, but never a backtick.
          open = marker unless rest.includes?('`')
        elsif marker.size >= open.size && rest.strip.empty?
          open = nil
        end
      end

      open.nil? ? text : "#{text}\n#{open}"
    end

    private def self.abbreviate(text : String) : String
      return text if text.size <= ABBREVIATED_CHARS

      "#{text[0, ABBREVIATED_CHARS]}\n… (abbreviated; #{text.size} characters in total)"
    end

    private def self.quote(text : String) : String
      text.lines.map { |line| "> #{line.rstrip}".rstrip }.join("\n") + "\n"
    end

    # Tool output is full of backticks — a `bash` result quoting a Markdown file
    # is enough — and a three-backtick fence would close on the first of them,
    # turning the rest of the export into garbage. So the fence is always longer
    # than the longest run inside it.
    private def self.fenced(md : String::Builder, content : String, language : String = "") : Nil
      longest = content.scan(/`+/).map(&.[0].size).max? || 0
      fence = "`" * Math.max(3, longest + 1)

      md << fence << language << "\n" << content
      md << "\n" unless content.ends_with?("\n")
      md << fence << "\n"
    end
  end
end
