require "base64"

module Smith
  # What a file *is*, decided from its bytes.
  #
  # An extension is a claim, not a fact: a screenshot saved as `.txt` is still
  # a PNG, and a text file named `.png` is still text. Sending the second one
  # as an image is a provider error the user cannot act on, so the signature
  # decides and the name is only ever shown.
  module Media
    # How much of a file has to be read to recognise it. WebP needs twelve
    # bytes — `RIFF` at 0, `WEBP` at 8 — and that is the longest signature
    # here.
    SNIFF_BYTES = 12

    # Base64 inflates by a third, and the result is not sent once: it goes
    # into the session file and back out in *every* later request of the
    # session. 3 MB before encoding is around 4 MB on the wire, per turn.
    DEFAULT_MAX_BYTES = 3 * 1024 * 1024

    # Images and documents travel in differently shaped blocks and not every
    # provider takes both, so the difference is carried rather than derived
    # from the media type at each use.
    enum Kind
      Image
      Document
    end

    record Format, media_type : String, kind : Kind

    PNG  = Format.new("image/png", Kind::Image)
    JPEG = Format.new("image/jpeg", Kind::Image)
    GIF  = Format.new("image/gif", Kind::Image)
    WEBP = Format.new("image/webp", Kind::Image)
    PDF  = Format.new("application/pdf", Kind::Document)

    # A file smith is willing to attach, already encoded.
    struct Attachment
      getter format : Format
      getter data : String
      getter bytes : Int32

      def initialize(@format : Format, @data : String, @bytes : Int32)
      end

      def media_type : String
        @format.media_type
      end

      def kind : Kind
        @format.kind
      end

      def image? : Bool
        @format.kind.image?
      end
    end

    # nil for anything not recognised. Deliberately not a guess: an unknown
    # binary is refused rather than labelled `application/octet-stream` and
    # sent in the hope that the provider works it out.
    def self.detect(bytes : Bytes) : Format?
      return PNG if starts_with?(bytes, UInt8.static_array(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A))
      return JPEG if starts_with?(bytes, UInt8.static_array(0xFF, 0xD8, 0xFF))
      return GIF if starts_with?(bytes, UInt8.static_array(0x47, 0x49, 0x46, 0x38))
      return PDF if starts_with?(bytes, UInt8.static_array(0x25, 0x50, 0x44, 0x46))

      if starts_with?(bytes, UInt8.static_array(0x52, 0x49, 0x46, 0x46)) &&
         bytes.size >= 12 && bytes[8, 4] == Bytes[0x57, 0x45, 0x42, 0x50]
        return WEBP
      end

      nil
    end

    # Reads only the signature, so deciding what a file is never costs the
    # price of loading it.
    def self.detect_file(path : String) : Format?
      File.open(path) do |file|
        buffer = Bytes.new(SNIFF_BYTES)
        read = file.read(buffer)
        detect(buffer[0, read])
      end
    rescue IO::Error
      nil
    end

    # nil when the file is not a format smith attaches. The size limit is the
    # caller's to enforce — it is the caller that knows how to report a skip.
    def self.read(path : String) : Attachment?
      format = detect_file(path)
      return nil if format.nil?

      raw = File.read(path).to_slice
      Attachment.new(format, Base64.strict_encode(raw), raw.size)
    rescue IO::Error
      nil
    end

    def self.human_size(bytes : Int32) : String
      return "#{bytes} B" if bytes < 1024
      kb = bytes / 1024.0
      return "#{kb.round(1)} KB" if kb < 10
      return "#{kb.round.to_i} KB" if kb < 1024
      "#{(kb / 1024.0).round(1)} MB"
    end

    private def self.starts_with?(bytes : Bytes, signature) : Bool
      return false if bytes.size < signature.size
      signature.each_with_index { |byte, index| return false if bytes[index] != byte }
      true
    end
  end
end
