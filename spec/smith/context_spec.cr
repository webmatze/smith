require "../spec_helper"
require "../../src/smith/context"

# The invariant the whole module exists to protect: every tool_use has exactly
# one tool_result with the same id, and every tool_result has its tool_use.
# Anthropic and OpenAI reject the request outright otherwise, so this is
# asserted after *every* compaction below, not just in one dedicated example.
private def assert_tool_pairing(messages : Array(Smith::LLM::Message))
  uses = [] of String
  results = [] of String

  messages.each do |message|
    message.content.each do |block|
      case block.type
      when .tool_use?    then uses << block.tool_call_id.not_nil!
      when .tool_result? then results << block.tool_call_id.not_nil!
      end
    end
  end

  uses.sort.should eq(results.sort)
  uses.size.should eq(uses.uniq.size)
end

private def user_msg(text : String)
  Smith::LLM::Message.user(text)
end

private def assistant_tool_call(id : String, name : String = "bash")
  Smith::LLM::Message.assistant_with_blocks([
    Smith::LLM::ContentBlock.tool_use(id, name, JSON.parse(%({"command": "ls"}))),
  ])
end

private def tool_result(id : String, text : String, is_error = false)
  Smith::LLM::Message.tool_results([
    Smith::LLM::ContentBlock.tool_result(id, text, is_error),
  ])
end

# Builds `turns` complete turns, each: user -> assistant(tool_use) -> tool_result
private def conversation(turns : Int32, result_bytes : Int32 = 8_000)
  messages = [] of Smith::LLM::Message

  turns.times do |i|
    messages << user_msg("request number #{i}")
    messages << assistant_tool_call("call-#{i}")
    messages << tool_result("call-#{i}", "x" * result_bytes)
  end

  messages
end

private def compact_with_summary(messages, max_tokens, summary = "the earlier work")
  Smith::Context.compact(messages, max_tokens) { |_| summary }
end

describe Smith::Context do
  describe ".estimate_tokens" do
    it "grows with the amount of content" do
      small = Smith::Context.estimate_tokens(conversation(1, result_bytes: 100))
      large = Smith::Context.estimate_tokens(conversation(1, result_bytes: 100_000))

      large.should be > small
    end

    it "counts tool arguments, not only text" do
      with_args = [assistant_tool_call("c1")]
      Smith::Context.estimate_tokens(with_args).should be > 0
    end
  end

  describe ".compact" do
    it "leaves a history under budget completely untouched" do
      messages = conversation(2, result_bytes: 100)
      result = compact_with_summary(messages, 100_000)

      result.compacted?.should be_false
      result.strategy.should eq(Smith::Context::Strategy::None)
      result.messages.should be(messages)
      assert_tool_pairing(result.messages)
    end

    it "truncates oldest-first and stops as soon as the budget is met" do
      # 8 x 20 KiB ~= 40k tokens; a 25k budget needs roughly half of them cut.
      messages = conversation(8, result_bytes: 20_000)
      result = compact_with_summary(messages, 25_000)

      result.strategy.should eq(Smith::Context::Strategy::Truncated)
      result.after_tokens.should be <= 25_000
      result.after_tokens.should be < result.before_tokens
      assert_tool_pairing(result.messages)

      results = result.messages.flat_map(&.content).select(&.type.tool_result?)
      results.size.should eq(8)

      # Oldest is cut...
      results.first.text.not_nil!.should contain("truncated by smith")
      results.first.text.not_nil!.bytesize.should be < 20_000

      # ...and the newest survives whole, because the loop stopped early.
      results.last.text.not_nil!.bytesize.should eq(20_000)
    end

    it "will cut even a single oversized result rather than give up" do
      # The common real case: one giant `cat` blowing the window. An exemption
      # for recent results would have made this untouchable.
      messages = [
        user_msg("show me the file"),
        assistant_tool_call("c1"),
        tool_result("c1", "z" * 400_000),
      ]

      result = compact_with_summary(messages, 1_000)

      result.after_tokens.should be < result.before_tokens
      block = result.messages.last.content.first
      block.text.not_nil!.should contain("truncated by smith")
      assert_tool_pairing(result.messages)
    end

    it "reports None when it genuinely could not shrink anything" do
      # Over budget, but nothing is truncatable and there is no later turn to
      # cut to — so it must not claim a compaction that did not happen.
      messages = [user_msg("x" * 40_000)]

      result = compact_with_summary(messages, 100)

      result.strategy.should eq(Smith::Context::Strategy::None)
      result.compacted?.should be_false
    end

    it "preserves is_error when truncating" do
      messages = [] of Smith::LLM::Message
      8.times do |i|
        messages << user_msg("q#{i}")
        messages << assistant_tool_call("c#{i}")
        messages << tool_result("c#{i}", "y" * 20_000, is_error: true)
      end

      result = compact_with_summary(messages, 25_000)

      truncated = result.messages.flat_map(&.content).select(&.type.tool_result?).first
      truncated.is_error.should be_true
      assert_tool_pairing(result.messages)
    end

    it "summarizes the oldest turns when truncation is not enough" do
      messages = conversation(10, result_bytes: 60_000)
      result = compact_with_summary(messages, 1_000, summary: "we listed files")

      result.strategy.should eq(Smith::Context::Strategy::Summarized)
      result.messages.first.role.user?.should be_true
      result.messages.first.content.first.text.not_nil!.should contain("we listed files")
      result.messages.size.should be < messages.size
      assert_tool_pairing(result.messages)
    end

    it "never cuts into the middle of a turn" do
      messages = conversation(10, result_bytes: 60_000)
      result = compact_with_summary(messages, 1_000)

      # Everything after the injected summary must still start at a turn
      # boundary, so no tool_result can precede its tool_use.
      result.messages[1].role.user?.should be_true
      assert_tool_pairing(result.messages)
    end

    it "falls back to dropping the prefix when summarizing fails" do
      messages = conversation(10, result_bytes: 60_000)

      result = Smith::Context.compact(messages, 1_000) do |_|
        raise "provider exploded"
      end

      result.strategy.should eq(Smith::Context::Strategy::Dropped)
      result.messages.first.content.first.text.not_nil!.should contain("dropped")
      result.messages.size.should be < messages.size
      assert_tool_pairing(result.messages)
    end

    it "keeps the pairing intact across a range of budgets" do
      messages = conversation(12, result_bytes: 30_000)

      [50, 500, 5_000, 50_000].each do |budget|
        assert_tool_pairing(compact_with_summary(messages, budget).messages)
      end
    end
  end

  describe ".safe_cut_index" do
    it "only ever returns the index of a user message" do
      messages = conversation(6, result_bytes: 40_000)
      cut = Smith::Context.safe_cut_index(messages, 1_000)

      cut.should be > 0
      messages[cut].role.user?.should be_true
    end

    it "returns 0 when there is no later turn to cut to" do
      messages = [user_msg("only one turn"), assistant_tool_call("c1"), tool_result("c1", "out")]

      Smith::Context.safe_cut_index(messages, 1).should eq(0)
    end
  end
end

describe Smith::Context::Breakdown do
  it "counts text the same way compaction counts messages" do
    # If these two diverged, `smith context` would report a number the
    # compaction decision does not act on.
    text = "a" * 400
    message = Smith::LLM::Message.user(text)

    Smith::Context.estimate_text_tokens(text).should eq(Smith::Context.estimate_tokens([message]))
  end

  it "sums its parts and reports each as a share of the budget" do
    breakdown = Smith::Context::Breakdown.new(1000)
    breakdown.add("System prompt", "x" * 400) # 100 tokens
    breakdown.add("Messages", [Smith::LLM::Message.user("y" * 800)])

    breakdown.total.should eq(300)
    breakdown.percent(breakdown.total).should eq(30)
    breakdown.entries.map(&.label).should eq(["System prompt", "Messages"])
  end

  it "keeps an empty part visible rather than hiding it" do
    # "Skills 0" answers "are skills eating my context?"; a missing line does not.
    breakdown = Smith::Context::Breakdown.new(1000)
    breakdown.add("Skills", "")

    breakdown.entries.map(&.tokens).should eq([0])
  end
end
