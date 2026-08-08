require "../../../spec_helper"
require "../../../../src/smith/ui"

# A test double for terminal input: plays a script of keys, one read at a
# time. Strings become byte buffers, `:tick` raises IO::TimeoutError (the
# poll window expiring with nothing typed), and `:eof` ends the stream —
# the same three things a real terminal produces.
class ScriptedIO < IO
  def initialize(@script : Array(Symbol | String))
    @buffer = Bytes.empty
    @offset = 0
  end

  def read(slice : Bytes) : Int32
    byte = read_byte
    return 0 if byte.nil?
    slice[0] = byte
    1
  end

  def write(slice : Bytes) : Nil
    # Output is not under test here.
  end

  def read_byte : UInt8?
    if @offset < @buffer.size
      byte = @buffer[@offset]
      @offset += 1
      return byte
    end

    entry = @script.shift?
    case entry
    when nil
      nil
    when Symbol
      raise IO::TimeoutError.new if entry == :tick
      nil
    when String
      @buffer = entry.to_slice
      @offset = 1
      @buffer[0]
    end
  end
end

# An app whose terminal is fully scripted — specs drive it end to end without
# touching a real TTY. Accepts any array element type that fits the script,
# since a literal like `["a"]` infers to Array(String), not the union.
def app_with(script : Array = [] of Symbol | String, width = 80, height = 24) : Smith::UI::App
  terminal = Smith::UI::Terminal.new(
    IO::Memory.new,
    ScriptedIO.new(script.map { |entry| entry.as(Symbol | String) }),
    width: width,
    height: height
  )
  Smith::UI::App.new(terminal)
end
