require "json"
require "file_utils"
require "./atomic_file"
require "./paths"
require "./llm/types"
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

    def initialize(
      @id : String,
      @created_at : Time,
      @updated_at : Time,
      @first_prompt : String,
      @message_count : Int32,
      @name : String? = nil,
      @parent_id : String? = nil,
    )
    end

    # What to type to get this session back.
    def reference : String
      @name || @id
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
        parent_id: @parent_id
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
    def self.truncate(messages : Array(Smith::LLM::Message), index : Int32) : Array(Smith::LLM::Message)
      kept = messages[0, Math.min(index, messages.size)]

      # Drop any trailing assistant turn whose tool calls lost their results.
      while (last = kept.last?) && last.role.assistant? && last.content.any?(&.type.tool_use?)
        kept = kept[0, kept.size - 1]
      end

      kept
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

      Data.from_json(File.read(path))
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
      wanted = reference.strip
      entries = list

      if entries.any? { |e| e.id == wanted } || session_file?(wanted)
        return load(wanted)
      end

      matches = entries.select { |e| e.name == wanted }

      case matches.size
      when 0
        raise ArgumentError.new("Session '#{wanted}' not found. Run 'smith sessions' to see what there is.")
      when 1
        load(matches.first.id)
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

      AtomicFile.write(@index_path, entries.to_json)
    end
  end
end
