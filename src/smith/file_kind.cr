module Smith
  # Is this file text, or is it bytes we have no business putting in a prompt?
  #
  # One test, two callers: `@`-mentions skip such a file, `read_file` refuses
  # it. Both need the same answer, and a second copy of the rule is how the
  # two drift apart.
  module FileKind
    # How much of a file to look at when deciding whether it is text.
    SNIFF_BYTES = 1024

    # Null bytes in the first block. Crude, and the same test `grep` uses.
    # An empty file has none of them and is text.
    def self.binary?(path : String) : Bool
      File.open(path) do |file|
        buffer = Bytes.new(SNIFF_BYTES)
        read = file.read(buffer)
        buffer[0, read].includes?(0_u8)
      end
    rescue IO::Error
      true
    end
  end
end
