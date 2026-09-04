require "../spec_helper"
require "../../src/smith/transcript_log"
require "../../src/smith/agent"

private def with_log(&)
  dir = File.join(Dir.tempdir, "smith_tlog_#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(dir)
  begin
    yield Smith::TranscriptLog.new(dir), dir
  ensure
    FileUtils.rm_rf(dir) if Dir.exists?(dir)
  end
end

describe Smith::TranscriptLog do
  it "writes one message per line and reads them back" do
    with_log do |log, _dir|
      log.append([Smith::LLM::Message.user("first"), Smith::LLM::Message.user("second")])

      log.messages.map { |m| m.content.first.text }.should eq(["first", "second"])
    end
  end

  it "appends rather than replacing, so the record only ever grows" do
    with_log do |log, _dir|
      log.append([Smith::LLM::Message.user("first")])
      log.append([Smith::LLM::Message.user("second")])

      log.messages.size.should eq(2)
    end
  end

  it "does not create a file for nothing" do
    with_log do |log, _dir|
      log.append([] of Smith::LLM::Message)

      log.exists?.should be_false
    end
  end

  it "keeps tool calls and results intact, since that is what compaction mangles" do
    with_log do |log, _dir|
      call = Smith::LLM::Message.assistant_with_blocks([
        Smith::LLM::ContentBlock.tool_use("c1", "bash", JSON.parse(%({"command": "ls"}))),
      ])
      result = Smith::LLM::Message.tool_results([
        Smith::LLM::ContentBlock.tool_result("c1", "a" * 5_000, false),
      ])

      log.append([call, result])

      read = log.messages
      read[0].content.first.tool_call_id.should eq("c1")
      read[1].content.first.text.not_nil!.bytesize.should eq(5_000)
    end
  end

  it "skips a line it cannot parse rather than losing the rest" do
    with_log do |log, _dir|
      log.append([Smith::LLM::Message.user("first")])
      File.open(log.path, "a") { |f| f.puts "{not json" }
      log.append([Smith::LLM::Message.user("third")])

      log.messages.map { |m| m.content.first.text }.should eq(["first", "third"])
    end
  end

  it "counts the lines it skipped, so a shortened record cannot pass for an intact one" do
    with_log do |log, _dir|
      log.append([Smith::LLM::Message.user("first")])
      File.open(log.path, "a") { |f| f.puts "{not json" }
      File.open(log.path, "a") { |f| f.puts %({"role":"assistant","content":[{"type":) }
      log.append([Smith::LLM::Message.user("fourth")])

      messages, skipped = log.read

      messages.size.should eq(2)
      skipped.should eq(2)
    end
  end

  it "reports no damage for an intact log, and none for a log that is not there" do
    with_log do |log, _dir|
      log.read.should eq({[] of Smith::LLM::Message, 0})

      log.append([Smith::LLM::Message.user("first")])
      log.read[1].should eq(0)
    end
  end

  it "reports a log it cannot write once, then stops trying" do
    # A record of the session must not be able to take the session down.
    warnings = IO::Memory.new
    log = Smith::TranscriptLog.new("/proc/nonexistent-smith-test", warn_io: warnings)

    log.append([Smith::LLM::Message.user("hello")])
    log.append([Smith::LLM::Message.user("again")])

    log.failed?.should be_true
    warnings.to_s.scan(/Could not write/).size.should eq(1)
  end
end

class LoggingProvider < Smith::LLM::Provider
  getter calls = 0

  def name : String
    "mock"
  end

  def default_model : String
    "mock-model"
  end

  def complete(request : Smith::LLM::Request) : Smith::LLM::Response
    @calls += 1
    Smith::LLM::Response.new("resp_#{@calls}", request.model, [
      Smith::LLM::ContentBlock.text("answer #{@calls}"),
    ])
  end
end

describe "what the agent puts on the record" do
  it "records the turn, including the messages that arrive after the last compaction check" do
    with_log do |log, _dir|
      agent = Smith::Agent.new(
        provider: LoggingProvider.new,
        registry: Smith::Tools::Registry.new,
        transcript_log: log
      )

      agent.send("hello")

      log.messages.map(&.role).should eq([Smith::LLM::Role::User, Smith::LLM::Role::Assistant])
    end
  end

  it "records each message once across several turns" do
    with_log do |log, _dir|
      agent = Smith::Agent.new(
        provider: LoggingProvider.new,
        registry: Smith::Tools::Registry.new,
        transcript_log: log
      )

      agent.send("one")
      agent.send("two")

      log.messages.size.should eq(4)
      log.messages.map { |m| m.content.first.text }.should eq(["one", "answer 1", "two", "answer 2"])
    end
  end

  it "does not re-record a history it was handed, which is already on the record" do
    with_log do |log, _dir|
      existing = [Smith::LLM::Message.user("from disk")]
      log.seed(existing)

      agent = Smith::Agent.new(
        provider: LoggingProvider.new,
        registry: Smith::Tools::Registry.new,
        messages: existing.dup,
        transcript_log: log
      )

      agent.send("next")

      log.messages.map { |m| m.content.first.text }.should eq(["from disk", "next", "answer 1"])
    end
  end

  it "keeps what compaction discarded" do
    # The whole point: the session file holds the shortened history, so without
    # this the original is gone the moment compaction runs.
    with_log do |log, _dir|
      bulky = [] of Smith::LLM::Message
      6.times do |i|
        bulky << Smith::LLM::Message.user("request #{i}")
        bulky << Smith::LLM::Message.assistant_with_blocks([
          Smith::LLM::ContentBlock.tool_use("c#{i}", "bash", JSON.parse(%({"command": "ls"}))),
        ])
        bulky << Smith::LLM::Message.tool_results([
          Smith::LLM::ContentBlock.tool_result("c#{i}", "x" * 20_000, false),
        ])
      end
      log.seed(bulky)

      agent = Smith::Agent.new(
        provider: LoggingProvider.new,
        registry: Smith::Tools::Registry.new,
        messages: bulky.dup,
        context_settings: Smith::Config::ContextSettings.new(max_tokens: 30_000),
        transcript_log: log
      )

      agent.send("and now")

      agent.compactions.should be > 0
      shortened = agent.messages.flat_map(&.content).select(&.type.tool_result?).map(&.text.not_nil!.bytesize)
      shortened.any? { |size| size < 20_000 }.should be_true

      # The record still holds every result at its original size.
      recorded = log.messages.flat_map(&.content).select(&.type.tool_result?)
      recorded.size.should eq(6)
      recorded.map(&.text.not_nil!.bytesize).should eq([20_000] * 6)
    end
  end

  it "works without a log at all, because most callers have none" do
    agent = Smith::Agent.new(
      provider: LoggingProvider.new,
      registry: Smith::Tools::Registry.new
    )

    agent.send("hello")
    agent.messages.size.should eq(2)
  end
end
