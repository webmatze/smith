require "json"
require "file_utils"
require "./llm/types"

module Smith
  # The transcript as it actually was, before compaction shortened it.
  #
  # Compaction rewrites the message array in place and the session file holds
  # only that working history, so shortening a session is otherwise the same as
  # destroying the record of it — dropped thinking, stubbed results and
  # summarized-away turns are not recoverable from anything smith keeps.
  #
  # It is also the only basis on which anyone can later check whether the
  # compaction thresholds were good numbers. Without it, the next calibration
  # is guesswork again.
  #
  # Append-only, one JSON message per line, never read on the normal path. A
  # log that cannot be written is reported once and then given up on: a record
  # of the session must not be able to take the session down with it.
  class TranscriptLog
    getter path : String
    getter? failed : Bool = false

    def initialize(session_dir : String, @warn_io : IO = STDERR)
      @path = File.join(session_dir, "transcript.jsonl")
    end

    def exists? : Bool
      File.exists?(@path)
    end

    def append(messages : Array(LLM::Message)) : Nil
      return if messages.empty? || @failed

      begin
        FileUtils.mkdir_p(File.dirname(@path))
        File.open(@path, "a") do |file|
          messages.each { |message| file.puts(message.to_json) }
        end
      rescue ex
        @failed = true
        @warn_io.puts "⚠️  Could not write the transcript record at #{@path}: #{ex.message}"
      end
    end

    # Writes the history a session already had. Used once, for a session
    # recorded before this log existed: that is the longest transcript the user
    # has, and otherwise the only one that never gets a raw copy.
    def seed(messages : Array(LLM::Message)) : Nil
      append(messages)
    end

    # Only for reporting and tests — nothing on the normal path reads the log.
    def messages : Array(LLM::Message)
      read[0]
    end

    # The messages, and how many lines could not be read.
    #
    # One unreadable line must not make the rest unreachable — but it must not
    # pass unnoticed either. A record eight messages long that was nine is
    # indistinguishable from an intact one unless the loss is counted, and a
    # dropped `tool_result` leaves a tool call that appears never to have
    # returned. So the count comes back with the messages and the caller says
    # so out loud.
    def read : {Array(LLM::Message), Int32}
      return {[] of LLM::Message, 0} unless exists?

      skipped = 0
      messages = File.read_lines(@path).compact_map do |line|
        next if line.blank?
        begin
          LLM::Message.from_json(line)
        rescue
          skipped += 1
          nil
        end
      end

      {messages, skipped}
    end
  end
end
