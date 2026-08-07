require "json"
require "digest/sha256"
require "file_utils"
require "./atomic_file"

# Snapshots of the files a run is about to change, so a run can be taken back.
#
# smith may write and edit files. Without this the only way back is git, which
# only helps if you happened to commit first — rarely true mid-session. The
# point is to lower the cost of letting smith write at all, and with it the
# pressure to leave `--yes` on out of convenience.
#
# **`bash` is deliberately not covered.** What a shell command touches is not
# predictable, and a rewind that claims more than it delivers is worse than
# none. That limit is stated in the output and in the README.
module Smith::Checkpoints
  # Tools whose target file is known before the call.
  SNAPSHOT_TOOLS = %w[write_file edit_file]

  struct Entry
    include JSON::Serializable

    getter sequence : Int32
    getter tool : String
    getter path : String

    # sha256 of the content before the call; nil means the file did not exist,
    # so undoing the call means deleting it again.
    getter blob : String?

    # What smith left behind. Compared against the file at rewind time to spot
    # a change made outside smith since.
    property after_digest : String?

    getter message_index : Int32
    getter created_at : Time

    def initialize(
      @sequence : Int32,
      @tool : String,
      @path : String,
      @blob : String?,
      @message_index : Int32,
      @created_at : Time = Time.local,
      @after_digest : String? = nil,
    )
    end

    def id : String
      "%04d" % @sequence
    end

    def created? : Bool
      @blob.nil?
    end
  end

  struct RestoreResult
    getter restored : Array(String)
    getter deleted : Array(String)
    getter conflicts : Array(String)
    getter message_index : Int32?

    def initialize(
      @restored : Array(String) = [] of String,
      @deleted : Array(String) = [] of String,
      @conflicts : Array(String) = [] of String,
      @message_index : Int32? = nil,
    )
    end

    # A rewind held up by a conflict has not happened. The caller is told to
    # retry with --force, so nothing may be consumed in the meantime — neither
    # the checkpoints nor the transcript.
    def applied? : Bool
      @conflicts.empty?
    end

    def changed? : Bool
      !@restored.empty? || !@deleted.empty?
    end
  end

  class Store
    getter session_dir : String
    getter? enabled : Bool

    # Set by the agent before each batch of tool calls. The registry has no
    # business knowing about the transcript, so the position is handed in
    # rather than looked up.
    property current_message_index : Int32 = 0

    def initialize(@session_dir : String, @enabled : Bool = true)
    end

    def checkpoints_dir : String
      File.join(@session_dir, "checkpoints")
    end

    # Blobs are shared across all checkpoints of a session, not stored per
    # checkpoint — otherwise ten edits of one file would still keep ten copies,
    # which is exactly what content addressing is meant to avoid.
    def blobs_dir : String
      File.join(checkpoints_dir, "blobs")
    end

    def snapshot(tool : String, args : JSON::Any) : Entry?
      return nil unless @enabled
      return nil unless SNAPSHOT_TOOLS.includes?(tool)

      raw = args["path"]?.try(&.as_s?)
      return nil if raw.nil? || raw.empty?

      path = File.expand_path(raw)
      blob = File.exists?(path) ? store_blob(File.read(path)) : nil

      entry = Entry.new(
        sequence: next_sequence,
        tool: tool,
        path: path,
        blob: blob,
        message_index: @current_message_index
      )

      write_entry(entry)
      entry
    end

    # Called once the tool has run, so a later rewind can tell smith's own
    # change apart from one made afterwards by someone else.
    #
    # Not named `finalize`: that is Crystal's GC hook.
    def seal(entry : Entry) : Nil
      entry.after_digest = File.exists?(entry.path) ? Digest::SHA256.hexdigest(File.read(entry.path)) : nil
      write_entry(entry)
    end

    def list : Array(Entry)
      return [] of Entry unless Dir.exists?(checkpoints_dir)

      entries = Dir.children(checkpoints_dir).compact_map do |child|
        next unless child.ends_with?(".json")

        begin
          Entry.from_json(File.read(File.join(checkpoints_dir, child)))
        rescue
          # A corrupt checkpoint must not make the rest unreachable.
          nil
        end
      end

      entries.sort_by(&.sequence)
    end

    def blob_count : Int32
      return 0 unless Dir.exists?(blobs_dir)

      Dir.children(blobs_dir).size
    end

    # Undoes `target` and everything after it.
    #
    # Applied per file rather than per entry: the *newest* entry for a file
    # describes the state smith left it in, which is what an external change is
    # measured against, while the *oldest* holds the content to put back.
    def rewind_to(target : Entry, force : Bool = false, dry_run : Bool = false) : RestoreResult
      affected = list.select { |entry| entry.sequence >= target.sequence }

      restored = [] of String
      deleted = [] of String
      conflicts = [] of String

      affected.group_by(&.path).each do |path, entries|
        newest = entries.max_by(&.sequence)
        oldest = entries.min_by(&.sequence)

        if !force && externally_changed?(newest)
          conflicts << path
          next
        end

        if blob = oldest.blob
          restored << path
          File.write(path, read_blob(blob)) unless dry_run
        else
          deleted << path
          File.delete(path) if !dry_run && File.exists?(path)
        end
      end

      result = RestoreResult.new(restored, deleted, conflicts, target.message_index)

      # Consumed only once the rewind actually completed.
      if !dry_run && result.applied?
        affected.each { |entry| File.delete(entry_path(entry)) if File.exists?(entry_path(entry)) }
        collect_garbage
      end

      result
    end

    def prune(max : Int32, retention : Time::Span) : Nil
      entries = list
      cutoff = Time.local - retention

      doomed = entries.select { |entry| entry.created_at < cutoff }
      surviving = entries - doomed
      doomed.concat(surviving[0...-max]) if max > 0 && surviving.size > max

      doomed.each { |entry| File.delete(entry_path(entry)) if File.exists?(entry_path(entry)) }
      collect_garbage
    end

    private def externally_changed?(entry : Entry) : Bool
      expected = entry.after_digest
      # Nothing recorded — the call never completed, so there is nothing of
      # smith's to compare against.
      return false if expected.nil?

      return true unless File.exists?(entry.path)

      Digest::SHA256.hexdigest(File.read(entry.path)) != expected
    end

    private def next_sequence : Int32
      (list.map(&.sequence).max? || 0) + 1
    end

    private def entry_path(entry : Entry) : String
      File.join(checkpoints_dir, "#{entry.id}.json")
    end

    private def write_entry(entry : Entry) : Nil
      AtomicFile.write(entry_path(entry), entry.to_json)
    end

    private def store_blob(content : String) : String
      digest = Digest::SHA256.hexdigest(content)
      path = File.join(blobs_dir, digest)
      AtomicFile.write(path, content) unless File.exists?(path)
      digest
    end

    private def read_blob(digest : String) : String
      File.read(File.join(blobs_dir, digest))
    end

    # Blobs are shared, so one is only removable once no checkpoint refers to
    # it any more.
    private def collect_garbage : Nil
      return unless Dir.exists?(blobs_dir)

      referenced = list.compact_map(&.blob).to_set

      Dir.children(blobs_dir).each do |child|
        File.delete(File.join(blobs_dir, child)) unless referenced.includes?(child)
      end
    end
  end
end
