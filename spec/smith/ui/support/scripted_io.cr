require "../../../spec_helper"
require "../../../../src/smith/ui"

# A scripted input source.
#
# The scripts are raw key bytes, exactly what a terminal sends — and they are
# turned into events by termisu's own parser, so the specs keep covering the
# escape sequences they write rather than a second parser written for tests.
# `:tick` is a poll window that expired with nothing typed.
class ScriptedEvents
  # Set once the loop exists: an exhausted script means the input closed, and
  # that ends the session the same way a closed terminal would — including
  # any question still waiting for an answer.
  property loop : Anvil::Loop? = nil

  def initialize(script : Array(Symbol | String))
    @queue = Array(Termisu::Event::Any?).new
    script.each do |entry|
      case entry
      when :resize then @queue << Termisu::Event::Resize.new(80, 24)
      when Symbol  then @queue << nil
      when String  then ScriptedEvents.parse(entry).each { |event| @queue << event }
      end
    end
    @exhausted = false
  end

  # Bytes through a pipe into termisu's reader: the real parser, no terminal.
  def self.parse(bytes : String) : Array(Termisu::Event::Any)
    read_end, write_end = IO.pipe
    write_end.print(bytes)
    write_end.close
    reader = Termisu::Reader.new(read_end.fd)
    parser = Termisu::Input::Parser.new(reader)

    events = Array(Termisu::Event::Any).new
    while event = parser.poll_event(20)
      events << event
    end
    read_end.close
    events
  end

  def poll(timeout : Time::Span) : Termisu::Event::Any?
    if @queue.empty?
      unless @exhausted
        @exhausted = true
        loop.try &.input_closed!
      end
      # Yield rather than spin: the turn fibers the specs spawn need a chance
      # to run, and a real poll would be blocking here anyway.
      sleep 1.millisecond
      return nil
    end

    event = @queue.shift
    sleep 1.millisecond if event.nil?
    event
  end
end

# An app whose terminal is fully scripted — specs drive it end to end without
# touching a real TTY. Accepts any array element type that fits the script,
# since a literal like `["a"]` infers to Array(String), not the union.
def app_with(script : Array = [] of Symbol | String, width = 80, height = 24) : Smith::UI::App
  events = ScriptedEvents.new(script.map { |entry| entry.as(Symbol | String) })
  surface = Anvil::Surface::Inline.memory(IO::Memory.new, width, height, 1)
  loop = Anvil::Loop.new(->(timeout : Time::Span) { events.poll(timeout) }, target_fps: 1000)
  events.loop = loop
  Smith::UI::App.new(Anvil::App.new(surface, loop))
end
