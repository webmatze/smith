require "json"
require "file_utils"
require "digest/sha256"
require "./atomic_file"
require "./paths"
require "./llm/types"
require "./pricing"
require "./todos"

module Smith::Session
  struct IndexEntry
    include JSON::Serializable

    getter id : String
    getter created_at : Time
    getter updated_at : Time
    getter first_prompt : String
    getter message_count : Int32

    # Index files written before names existed simply have no field.
    getter name : String? = nil
    getter parent_id : String? = nil

    # Index files written before costs were listed have none of these; the
    # row shows `n/a` rather than guessing or breaking the list.
    getter provider : String? = nil
    getter model : String? = nil
    getter usage : Smith::LLM::Usage? = nil

    def initialize(
      @id : String,
      @created_at : Time,
      @updated_at : Time,
      @first_prompt : String,
      @message_count : Int32,
      @name : String? = nil,
      @parent_id : String? = nil,
      @provider : String? = nil,
      @model : String? = nil,
      @usage : Smith::LLM::Usage? = nil,
    )
    end

    # What to type to get this session back.
    def reference : String
      @name || @id
    end

    # What the tokens came to, per the pricing table and any `[pricing]`
    # overrides. nil when the rate is unknown or the entry predates usage
    # tracking — a wrong cost figure is worse than no cost figure.
    def cost(overrides : Smith::Pricing::Overrides? = nil) : Float64?
      provider = @provider
      model = @model
      usage = @usage
      return nil if provider.nil? || model.nil? || usage.nil?

      Smith::Pricing.estimate(usage, provider, model, overrides)
    end
  end

  # Turns a first prompt into something a human would type at a shell.
  #
  # Deliberately not an LLM call: naming a session is not worth a provider
  # roundtrip, and a mechanical name is predictable in a way a generated one
  # is not.
  module Naming
    WORDS = 5

    def self.derive(prompt : String) : String?
      words = prompt
        .downcase
        .gsub(/[^a-z0-9\s-]/, " ")
        .split(/\s+/)
        .reject(&.empty?)
        .first(WORDS)

      return nil if words.empty?

      name = words.join("-").strip('-')
      name.empty? ? nil : name
    end
  end

  class Data
    include JSON::Serializable

    getter id : String
    getter created_at : Time
    property updated_at : Time
    property cwd : String
    property model : String
    property provider : String
    property messages : Array(Smith::LLM::Message)
    property usage : Smith::LLM::Usage

    # Sessions written before the todo tool existed simply have no field. The
    # same goes for name and parent_id: both default so older files load.
    property todos : Array(Smith::TodoList::Item) = Array(Smith::TodoList::Item).new
    property name : String? = nil
    property parent_id : String? = nil

    # How far the token estimate was off, last time the provider said. Carried
    # across a resume so the first turn back is not blind about a long history.
    property context_ratio : Float64 = 1.0

    def initialize(
      @id : String,
      @cwd : String,
      @model : String,
      @provider : String,
      @messages : Array(Smith::LLM::Message) = Array(Smith::LLM::Message).new,
      @usage : Smith::LLM::Usage = Smith::LLM::Usage.new(0, 0, 0),
      @todos : Array(Smith::TodoList::Item) = Array(Smith::TodoList::Item).new,
      @created_at : Time = Time.local,
      @updated_at : Time = Time.local,
      @name : String? = nil,
      @parent_id : String? = nil,
    )
    end

    def first_prompt : String
      user_msg = @messages.find { |m| m.role.user? }
      return "(empty session)" if user_msg.nil?

      text_block = user_msg.content.find { |b| b.type.text? }
      return "(empty prompt)" if text_block.nil? || text_block.text.nil?

      txt = text_block.text.not_nil!.strip
      txt.size > 60 ? "#{txt[0..57]}..." : txt
    end

    def to_index_entry : IndexEntry
      IndexEntry.new(
        id: @id,
        created_at: @created_at,
        updated_at: @updated_at,
        first_prompt: first_prompt,
        message_count: @messages.size,
        name: @name,
        parent_id: @parent_id,
        provider: @provider,
        model: @model,
        usage: @usage
      )
    end

    # What to type to get this session back.
    def reference : String
      @name || @id
    end

    # True when first_prompt is one of its own placeholders rather than
    # something the user actually typed.
    def prompted? : Bool
      @messages.any? { |m| m.role.user? && m.content.any? { |b| b.type.text? && !b.text.try(&.strip).nil? } }
    end
  end

  # Cutting the transcript is not a plain slice: providers reject a request
  # where a tool_use has no matching tool_result, the same invariant
  # Context.compact upholds.
  module Transcript
    # Where the transcript has to be cut so that `id` is the last message left.
    #
    # nil means the message is not there any more — compaction replaced it with
    # a summary. That is a real answer, not a failure: a rewind to such a
    # checkpoint restores its files and leaves the transcript alone, rather
    # than guessing at a position and cutting somewhere else.
    def self.index_after(messages : Array(Smith::LLM::Message), id : String) : Int32?
      messages.index { |message| message.id == id }.try(&.+(1))
    end

    def self.truncate(messages : Array(Smith::LLM::Message), index : Int32) : Array(Smith::LLM::Message)
      kept = messages[0, Math.min(index, messages.size)]

      # Drop any trailing assistant turn whose tool calls lost their results.
      while (last = kept.last?) && last.role.assistant? && last.content.any?(&.type.tool_use?)
        kept = kept[0, kept.size - 1]
      end

      kept
    end
  end

  # Parses the `--older-than` span of `sessions prune`: "30d", "12h", "15m".
  # A bare number means days, because that is the unit retention is measured
  # in. Anything else is a typo the user should see, not guess at.
  module Retention
    def self.parse(input : String) : Time::Span
      match = input.strip.match(/\A(\d+(?:\.\d+)?)\s*([dhm])?\z/i)
      raise ArgumentError.new("Cannot parse '#{input}' as a duration — try e.g. 30d, 12h or 15m.") if match.nil?

      amount = match[1].to_f
      unit = (match[2]? || "d").downcase

      case unit
      when "d" then amount.days
      when "h" then amount.hours
      else          amount.minutes
      end
    end
  end

  class Store
    getter base_dir : String
    getter sessions_dir : String
    getter index_path : String

    def initialize(base_dir : String? = nil)
      @base_dir = base_dir || Smith.home_dir
      @sessions_dir = File.join(@base_dir, "sessions")
      @index_path = File.join(@sessions_dir, "index.json")

      FileUtils.mkdir_p(@sessions_dir, mode: 0o700)
    end

    def new_id : String
      "session-#{Time.local.to_unix}-#{Random::Secure.hex(3)}"
    end

    def create(model : String, provider : String, cwd : String = Dir.current) : Data
      data = Data.new(
        id: new_id,
        cwd: cwd,
        model: model,
        provider: provider
      )

      save(data)
      data
    end

    # A session owns a directory now, so its checkpoints have somewhere to
    # live next to it.
    def session_dir(id : String) : String
      File.join(@sessions_dir, id)
    end

    # Where attachment bytes live. Content-addressed, like the checkpoint
    # blobs: the same screenshot mentioned in five turns is stored once.
    def media_dir(id : String) : String
      File.join(session_dir(id), "media")
    end

    # `derive_name` and `check_name` exist so a rename can write a name the
    # normal path would have refused or replaced; everyday saves want both.
    def save(session : Data, derive_name : Bool = true, check_name : Bool = true) : Nil
      session.updated_at = Time.local

      if derive_name && session.name.nil? && session.prompted?
        session.name = unique_name(Naming.derive(session.first_prompt), session.id)
      end

      if check_name && (name = session.name)
        assert_available(name, session.id)
      end

      # Before the JSON is built, because externalizing is what puts the
      # `media_ref` into the block that the JSON is supposed to carry.
      externalize_media(session)

      AtomicFile.write(File.join(session_dir(session.id), "session.json"), session.to_json)

      # Sessions written before the directory layout keep working, and are
      # migrated the first time they are saved again.
      legacy = legacy_path(session.id)
      File.delete(legacy) if File.exists?(legacy)

      update_index(session.to_index_entry)
    end

    def load(id : String) : Data
      path = File.join(session_dir(id), "session.json")
      path = legacy_path(id) unless File.exists?(path)

      unless File.exists?(path)
        raise ArgumentError.new("Session '#{id}' not found at #{path}")
      end

      data = Data.from_json(File.read(path))
      restore_media(data)
      data
    end

    # Attachment bytes go into files of their own, and the message keeps only
    # the digest that finds them again.
    #
    # They cannot stay in session.json: the base64 is resent on every turn of
    # the session anyway, and a copy in the session file — plus the second one
    # the raw transcript log would take — turns a 400 KB screenshot into
    # megabytes of JSON that nothing ever reads. What the JSON needs is enough
    # to know an image was there and how to get it back.
    private def externalize_media(session : Data) : Nil
      dir = media_dir(session.id)

      session.messages.each do |message|
        message.content.each do |block|
          data = block.data
          next if data.nil?

          # Not skipped when the block already has a ref: a fork inherits the
          # transcript of another session, and its own directory has none of
          # the files yet. Reusing the known digest is what keeps that from
          # costing a hash of every attachment on every save.
          digest = block.media_ref || Digest::SHA256.hexdigest(data)
          path = File.join(dir, digest)
          AtomicFile.write(path, data) unless File.exists?(path)
          block.media_ref = digest
        end
      end
    end

    # A missing file is not fatal: the transcript still says an image was
    # attached, and losing the bytes is better than refusing to open the
    # session that mentions them.
    private def restore_media(session : Data) : Nil
      dir = media_dir(session.id)

      session.messages.each do |message|
        message.content.each do |block|
          ref = block.media_ref
          next if ref.nil? || !block.data.nil?

          path = File.join(dir, ref)
          block.data = File.read(path) if File.exists?(path)
        end
      end
    end

    private def legacy_path(id : String) : String
      File.join(@sessions_dir, "#{id}.json")
    end

    def list : Array(IndexEntry)
      return Array(IndexEntry).new unless File.exists?(@index_path)

      begin
        entries = Array(IndexEntry).from_json(File.read(@index_path))
        entries.sort_by { |e| -e.updated_at.to_unix }
      rescue
        Array(IndexEntry).new
      end
    end

    def latest : Data?
      entries = list
      return nil if entries.empty?
      load(entries.first.id)
    end

    # A reference is whatever the user typed: an id or a name. An id wins,
    # since it is unambiguous by construction.
    def resolve(reference : String) : Data
      load(resolve_id(reference))
    end

    # Resolution without loading: works on the index and the filesystem, so a
    # session whose file is gone (or half-written) can still be named.
    private def resolve_id(reference : String) : String
      wanted = reference.strip
      entries = list

      return wanted if entries.any? { |e| e.id == wanted } || session_file?(wanted)

      matches = entries.select { |e| e.name == wanted }

      case matches.size
      when 0
        raise ArgumentError.new("Session '#{wanted}' not found. Run 'smith sessions' to see what there is.")
      when 1
        matches.first.id
      else
        # Only reachable if session files were edited by hand, but picking one
        # silently would resume the wrong conversation.
        listing = matches.map { |e| "  #{e.id}  (updated #{e.updated_at})" }.join("\n")
        raise ArgumentError.new("Session name '#{wanted}' is ambiguous:\n#{listing}\nUse the id instead.")
      end
    end

    def rename(reference : String, name : String) : Data
      session = resolve(reference)
      wanted = name.strip

      raise ArgumentError.new("A session name cannot be empty.") if wanted.empty?
      assert_available(wanted, session.id)

      session.name = wanted
      save(session, derive_name: false)
      session
    end

    # A copy under a new id, so one conversation can be taken two ways. The
    # original is untouched — including its checkpoints, which stay with it.
    def fork(reference : String) : Data
      source = resolve(reference)

      copy = Data.new(
        id: new_id,
        cwd: source.cwd,
        model: source.model,
        provider: source.provider,
        messages: source.messages.dup,
        usage: source.usage,
        todos: source.todos.dup,
        name: unique_name(source.name.try { |n| "#{n}-fork" }, nil),
        parent_id: source.id
      )
      # The fork inherits the transcript, so it must inherit what was learned
      # about measuring it — otherwise its first turn is blind about a history
      # the parent already knew the size of.
      copy.context_ratio = source.context_ratio

      save(copy, derive_name: false, check_name: false)
      copy
    end

    # Removes a session completely: index entry, directory (checkpoints, bash
    # logs, media blobs), and any legacy flat file. Resolved the same way
    # `resume` resolves, so a name works as well as an id — but against the
    # index rather than the loaded transcript, so a half-written session can
    # still be cleaned up. Returns the index entry when there was one.
    def delete(reference : String) : IndexEntry?
      entry = resolve_entry(reference)
      remove(entry.try(&.id) || reference)
      entry
    end

    # Resolution that stops at the index entry — what delete and its dry-run
    # share. Raises like resolve does when the reference names nothing.
    def resolve_entry(reference : String) : IndexEntry?
      id = resolve_id(reference)
      list.find { |e| e.id == id }
    end

    # What `prune` would remove: every entry whose `updated_at` is older than
    # the cutoff, except — always — the newest session, and additionally the
    # newest `keep_last` when given. `protect` shields one more id, which is
    # how a resume keeps the session it asked for from expiring mid-start.
    # Returned oldest first.
    def prune_candidates(older_than : Time::Span, keep_last : Int32 = 0, protect : String? = nil) : Array(IndexEntry)
      entries = list
      return Array(IndexEntry).new if entries.size <= 1

      cutoff = Time.local - older_than
      doomed = entries.select { |e| e.updated_at < cutoff }

      # Math.max keeps the newest session alive even with keep_last = 0:
      # pruning everything you have is rarely what was asked for.
      shielded = entries.first(Math.max(keep_last, 1)).map(&.id).to_set
      shielded.add(protect) if protect

      doomed.reject { |e| shielded.includes?(e.id) }.reverse
    end

    # Deletes what prune_candidates selects and returns it; with `dry_run`
    # nothing is touched and the return value is what would go.
    def prune(older_than : Time::Span, keep_last : Int32 = 0, protect : String? = nil, dry_run : Bool = false) : Array(IndexEntry)
      doomed = prune_candidates(older_than, keep_last, protect)
      doomed.each { |entry| remove(entry.id) } unless dry_run
      doomed
    end

    private def remove(id : String) : Nil
      # Index first: interrupted before the files go, what is left is an
      # invisible orphan directory; the other way round the index would keep
      # naming a session that is no longer there.
      write_index(list.reject { |e| e.id == id })

      dir = session_dir(id)
      FileUtils.rm_rf(dir) if Dir.exists?(dir)

      legacy = legacy_path(id)
      File.delete(legacy) if File.exists?(legacy)
    end

    private def session_file?(id : String) : Bool
      File.exists?(File.join(session_dir(id), "session.json")) || File.exists?(legacy_path(id))
    end

    private def assert_available(name : String, owner_id : String) : Nil
      taken = list.find { |e| e.name == name && e.id != owner_id }
      return if taken.nil?

      raise ArgumentError.new("The name '#{name}' is already used by session #{taken.id}.")
    end

    # Derived names collide easily — two "fix the tests" sessions in a week is
    # normal — and a collision would make resuming by name ambiguous, so the
    # duplicate gets a counter rather than the ambiguity.
    private def unique_name(candidate : String?, owner_id : String?) : String?
      return nil if candidate.nil?

      taken = list.reject { |e| e.id == owner_id }.compact_map(&.name).to_set
      return candidate unless taken.includes?(candidate)

      counter = 2
      while taken.includes?("#{candidate}-#{counter}")
        counter += 1
      end
      "#{candidate}-#{counter}"
    end

    private def update_index(new_entry : IndexEntry)
      entries = list
      existing_idx = entries.index { |e| e.id == new_entry.id }

      if existing_idx
        entries[existing_idx] = new_entry
      else
        entries.unshift(new_entry)
      end

      write_index(entries)
    end

    private def write_index(entries : Array(IndexEntry)) : Nil
      AtomicFile.write(@index_path, entries.to_json)
    end
  end
end
