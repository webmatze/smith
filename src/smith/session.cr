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

    def initialize(@id : String, @created_at : Time, @updated_at : Time, @first_prompt : String, @message_count : Int32)
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

    # Sessions written before the todo tool existed simply have no field.
    property todos : Array(Smith::TodoList::Item) = Array(Smith::TodoList::Item).new

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
        message_count: @messages.size
      )
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

    def create(model : String, provider : String, cwd : String = Dir.current) : Data
      timestamp = Time.local.to_unix
      random_suffix = Random::Secure.hex(3)
      session_id = "session-#{timestamp}-#{random_suffix}"

      data = Data.new(
        id: session_id,
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

    def save(session : Data) : Nil
      session.updated_at = Time.local

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
