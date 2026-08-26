require "json"
require "../file_kind"
require "../media"
require "../llm/types"
require "./tool"

module Smith::Tools
  class ReadFile < Tool
    include ParallelTool

    MAX_BYTES = 256 * 1024 # 256 KiB cap

    # The same ceiling an @-mention uses, `[media] max_bytes`. How a file got
    # into the context says nothing about what it costs once it is there.
    def initialize(@max_media_bytes : Int32 = Smith::Media::DEFAULT_MAX_BYTES)
    end

    def name : String
      "read_file"
    end

    def description : String
      "Read a file from disk. Text comes back with line numbers and an optional line range; a PNG, JPEG, GIF, WebP or PDF comes back as the image or document itself."
    end

    def parameters : JSON::Any
      JSON.parse(%({
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "Absolute or relative file path to read."
          },
          "start_line": {
            "type": "integer",
            "description": "Optional 1-based start line number."
          },
          "end_line": {
            "type": "integer",
            "description": "Optional 1-based end line number."
          }
        },
        "required": ["path"]
      }))
    end

    def run(args : JSON::Any) : String
      answer(args, encode: false)[0]
    end

    # Never nil: a text read must not go down the fallback path, or the
    # registry would call `run` afterwards and read the same file twice.
    def run_with_media(args : JSON::Any) : Tuple(String, Array(Smith::LLM::ContentBlock))?
      answer(args, encode: true)
    end

    # `encode` is what separates the two entry points. Deciding *that* a file
    # is an image is free — twelve bytes of signature — but base64 of a
    # screenshot costs a third of its size on top, and the text-only caller
    # has no use for it.
    private def answer(args : JSON::Any, encode : Bool) : Tuple(String, Array(Smith::LLM::ContentBlock))
      none = Array(Smith::LLM::ContentBlock).new

      path = args["path"]?.try(&.as_s?)
      return {"Error: 'path' parameter is required.", none} if path.nil?

      unless File.exists?(path)
        return {"Error: File '#{path}' does not exist.", none}
      end

      if File.directory?(path)
        return {"Error: Path '#{path}' is a directory, not a file.", none}
      end

      # Before the binary guard, not after: an image *is* binary, and the
      # signature is what tells the two apart. A screenshot saved as
      # `notes.txt` comes back as the PNG it is, and a text file named
      # `shot.png` falls through to the text path below.
      if format = Smith::Media.detect_file(path)
        return attach(path, format, args, encode)
      end

      # The bytes of anything else binary are worth nothing here and cost a
      # slice of the context window every turn once they are in the
      # transcript.
      if Smith::FileKind.binary?(path)
        return {"Error: File '#{path}' looks binary, not text. Use bash to inspect it.", none}
      end

      {read_text(path, args), none}
    end

    private def attach(
      path : String,
      format : Smith::Media::Format,
      args : JSON::Any,
      encode : Bool,
    ) : Tuple(String, Array(Smith::LLM::ContentBlock))
      none = Array(Smith::LLM::ContentBlock).new
      size = File.size(path)

      # A refusal, not a quiet re-encode: smith has no image library to scale
      # with, and half a picture is worse than an honest no.
      if size > @max_media_bytes
        return {
          "Error: '#{path}' is #{Smith::Media.human_size(size)}, over the " \
          "#{Smith::Media.human_size(@max_media_bytes)} attachment limit ([media] max_bytes). " \
          "Nothing was attached.",
          none,
        }
      end

      note = String.build do |str|
        str << "Attached '" << path << "' as " << format.media_type
        str << " (" << Smith::Media.human_size(size) << ")."

        # Answered rather than ignored: a line range on a picture is a
        # misunderstanding, and one the model can only correct if it is told.
        if args["start_line"]? || args["end_line"]?
          str << " A line range does not apply to " << (format.kind.image? ? "an image" : "a document") << "."
        end
      end

      return {note, none} unless encode

      attachment = Smith::Media.read(path)
      return {"Error: '#{path}' could not be read.", none} if attachment.nil?

      block = if attachment.image?
                Smith::LLM::ContentBlock.image(attachment.media_type, attachment.data, path)
              else
                Smith::LLM::ContentBlock.document(attachment.media_type, attachment.data, path)
              end

      {note, [block]}
    end

    private def read_text(path : String, args : JSON::Any) : String
      start_line = args["start_line"]?.try(&.as_i?)
      end_line = args["end_line"]?.try(&.as_i?)

      begin
        lines = File.read_lines(path)
        total_lines = lines.size

        s_idx = start_line ? {start_line - 1, 0}.max : 0
        e_idx = end_line ? {end_line - 1, total_lines - 1}.min : total_lines - 1

        if s_idx >= total_lines
          return "Error: start_line #{start_line} exceeds total file lines (#{total_lines})."
        end

        selected_lines = lines[s_idx..e_idx]? || Array(String).new

        result = String.build do |str|
          selected_lines.each_with_index(s_idx + 1) do |line, line_num|
            str.puts "#{line_num}: #{line}"
          end
        end

        if result.bytesize > MAX_BYTES
          truncated = result.byte_slice(0, MAX_BYTES)
          "#{truncated}\n\n... [Content truncated at 256 KiB limit]"
        else
          result
        end
      rescue ex : Exception
        "Error reading file '#{path}': #{ex.message}"
      end
    end
  end
end
