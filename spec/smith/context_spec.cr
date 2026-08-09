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

private def budget(
  max_tokens : Int32,
  compact_at : Float64 = Smith::Context::DEFAULT_COMPACT_AT,
  compact_to : Float64 = Smith::Context::DEFAULT_COMPACT_TO,
  overhead : Int32 = 0,
  ratio : Float64 = 1.0,
)
  Smith::Context::Budget.new(max_tokens, compact_at, compact_to, overhead, ratio)
end

private def compact_with_summary(messages, budget, summary = "the earlier work")
  Smith::Context.compact(messages, budget) { |_| summary }
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

    it "counts thinking signatures, which the provider is sent verbatim" do
      # Missing these made the estimator blind to what is often the largest
      # thing in an assistant turn.
      plain = [Smith::LLM::Message.assistant_with_blocks([
        Smith::LLM::ContentBlock.thinking("reasoning", nil),
      ])]
      signed = [Smith::LLM::Message.assistant_with_blocks([
        Smith::LLM::ContentBlock.thinking("reasoning", "s" * 4_000),
      ])]

      Smith::Context.estimate_tokens(signed).should eq(Smith::Context.estimate_tokens(plain) + 1_000)
    end
  end

  describe Smith::Context::Budget do
    it "derives trigger and target from the budget, so one number scales all three" do
      b = budget(100_000)

      b.trigger_tokens.should eq(80_000)
      b.target_tokens.should eq(50_000)
    end

    it "charges the overhead against the history" do
      budget(100_000, overhead: 10_000).charged(5_000).should eq(15_000)
    end

    it "charges the calibration ratio against the whole request" do
      budget(100_000, overhead: 10_000, ratio: 1.5).charged(10_000).should eq(30_000)
    end

    it "reports the history that still fits, which is the inverse of charging" do
      b = budget(100_000, overhead: 10_000, ratio: 1.25)

      b.charged(b.target_allowance).should be <= b.target_tokens
    end

    it "reports no allowance at all when the overhead alone fills the target" do
      budget(100_000, overhead: 90_000).target_allowance.should eq(0)
    end
  end

  describe ".compact" do
    it "leaves a history below the trigger byte-identical" do
      # Not merely equal — the same object. Rewriting the prefix invalidates
      # the provider's prompt cache, which is most of what made compacting
      # every turn expensive.
      messages = conversation(2, result_bytes: 100)
      result = compact_with_summary(messages, budget(100_000))

      result.compacted?.should be_false
      result.strategy.should eq(Smith::Context::Strategy::None)
      result.messages.should be(messages)
      assert_tool_pairing(result.messages)
    end

    it "acts at the trigger, before the budget is exceeded" do
      # ~10k tokens against a 12k budget: under the ceiling, over the 80%
      # trigger. Waiting for the ceiling is what let a single large result
      # push a request over it.
      messages = conversation(4, result_bytes: 10_000)
      before = Smith::Context.estimate_tokens(messages)
      b = budget(12_000)

      before.should be < b.max_tokens
      before.should be > b.trigger_tokens

      compact_with_summary(messages, b).compacted?.should be_true
    end

    it "compacts down to the target rather than to the first point that fits" do
      # The reported symptom, as a regression test: reclaiming just enough is
      # what made the next turn compact again.
      messages = conversation(8, result_bytes: 20_000)
      b = budget(40_000)
      result = compact_with_summary(messages, b)

      result.strategy.should eq(Smith::Context::Strategy::Truncated)
      result.after_tokens.should be <= b.target_tokens
      result.reached_target?.should be_true
      assert_tool_pairing(result.messages)

      results = result.messages.flat_map(&.content).select(&.type.tool_result?)
      results.size.should eq(8)

      # Oldest is cut...
      results.first.text.not_nil!.should contain(Smith::Context::TRUNCATION_MARKER)
      results.first.text.not_nil!.bytesize.should be < 20_000

      # ...and the newest survives whole, because the loop stopped early.
      results.last.text.not_nil!.bytesize.should eq(20_000)
    end

    it "does not compact a history it has just compacted" do
      messages = conversation(20, result_bytes: 20_000)
      b = budget(40_000)

      first = compact_with_summary(messages, b)
      first.compacted?.should be_true

      second = compact_with_summary(first.messages, b)
      second.strategy.should eq(Smith::Context::Strategy::None)
      second.messages.should be(first.messages)
    end

    it "compacts a handful of times over a long session, not every turn" do
      # The only test that exercises the reported symptom *as* a symptom: the
      # complaint was never about one call, it was about the cadence.
      messages = [] of Smith::LLM::Message
      compactions = 0
      b = budget(40_000)

      30.times do |i|
        messages << user_msg("request number #{i}")
        messages << assistant_tool_call("call-#{i}")
        messages << tool_result("call-#{i}", "x" * 8_000)

        result = compact_with_summary(messages, b)
        if result.compacted?
          compactions += 1
          messages = result.messages
        end

        assert_tool_pairing(messages)
      end

      compactions.should be < 5
    end

    it "counts the reserved overhead against every threshold" do
      # Same history, same ceiling: what differs is what else is in the
      # request. A history that fits alone need not fit alongside the tool
      # definitions.
      messages = conversation(8, result_bytes: 10_000)

      compact_with_summary(messages, budget(30_000)).compacted?.should be_false
      compact_with_summary(messages, budget(30_000, overhead: 8_000)).compacted?.should be_true
    end

    it "counts the calibration ratio against every threshold" do
      messages = conversation(4, result_bytes: 10_000)

      compact_with_summary(messages, budget(20_000)).compacted?.should be_false
      compact_with_summary(messages, budget(20_000, ratio: 2.0)).compacted?.should be_true
    end

    it "reports the cost of the request, not of the history alone" do
      messages = conversation(4, result_bytes: 10_000)
      b = budget(30_000, overhead: 15_000)

      result = compact_with_summary(messages, b)

      result.before_tokens.should eq(b.charged(Smith::Context.estimate_tokens(messages)))
    end

    it "will cut even a single oversized result rather than give up" do
      # The common real case: one giant `cat` blowing the window. An exemption
      # for recent results would have made this untouchable.
      messages = [
        user_msg("show me the file"),
        assistant_tool_call("c1"),
        tool_result("c1", "z" * 400_000),
      ]

      result = compact_with_summary(messages, budget(1_000))

      result.after_tokens.should be < result.before_tokens
      block = result.messages.last.content.first
      block.text.not_nil!.should contain(Smith::Context::TRUNCATION_MARKER)
      assert_tool_pairing(result.messages)
    end

    it "reports None when it genuinely could not shrink anything" do
      # Over budget, but nothing is truncatable and there is no later turn to
      # cut to — so it must not claim a compaction that did not happen.
      messages = [user_msg("x" * 40_000)]

      result = compact_with_summary(messages, budget(100))

      result.strategy.should eq(Smith::Context::Strategy::None)
      result.compacted?.should be_false
    end

    it "reports exhaustion when even the ceiling is out of reach" do
      # The caller stops the run on this rather than paying the provider to
      # reject the request.
      messages = [user_msg("x" * 40_000)]

      result = compact_with_summary(messages, budget(100))

      result.exhausted?.should be_true
      result.reached_target?.should be_false
    end

    it "does not report exhaustion when it got under the ceiling" do
      compact_with_summary(conversation(8, result_bytes: 20_000), budget(40_000)).exhausted?.should be_false
    end

    it "preserves is_error when truncating" do
      messages = [] of Smith::LLM::Message
      8.times do |i|
        messages << user_msg("q#{i}")
        messages << assistant_tool_call("c#{i}")
        messages << tool_result("c#{i}", "y" * 20_000, is_error: true)
      end

      result = compact_with_summary(messages, budget(40_000))

      truncated = result.messages.flat_map(&.content).select(&.type.tool_result?).first
      truncated.is_error.should be_true
      assert_tool_pairing(result.messages)
    end

    it "summarizes the oldest turns when truncation is not enough" do
      messages = conversation(10, result_bytes: 60_000)
      result = compact_with_summary(messages, budget(1_000), summary: "we listed files")

      result.strategy.should eq(Smith::Context::Strategy::Summarized)
      result.messages.first.role.user?.should be_true
      result.messages.first.content.first.text.not_nil!.should contain("we listed files")
      result.messages.size.should be < messages.size
      assert_tool_pairing(result.messages)
    end

    it "reports which stages ran" do
      truncated = compact_with_summary(conversation(8, result_bytes: 20_000), budget(40_000))
      truncated.stages.should eq(["truncate"])

      summarized = compact_with_summary(conversation(10, result_bytes: 60_000), budget(1_000))
      summarized.stages.should contain("summarize")
    end

    it "reports how many messages left the front, so checkpoints can follow" do
      messages = conversation(10, result_bytes: 60_000)
      result = compact_with_summary(messages, budget(1_000))

      # A prefix of N messages became one summary.
      result.removed_prefix.should eq(messages.size - result.messages.size)
      result.removed_prefix.should be > 0
    end

    it "reports nothing removed when it only truncated" do
      compact_with_summary(conversation(8, result_bytes: 20_000), budget(40_000)).removed_prefix.should eq(0)
    end

    it "never cuts into the middle of a turn" do
      messages = conversation(10, result_bytes: 60_000)
      result = compact_with_summary(messages, budget(1_000))

      # Everything after the injected summary must still start at a turn
      # boundary, so no tool_result can precede its tool_use.
      result.messages[1].role.user?.should be_true
      assert_tool_pairing(result.messages)
    end

    it "falls back to dropping the prefix when summarizing fails" do
      messages = conversation(10, result_bytes: 60_000)

      result = Smith::Context.compact(messages, budget(1_000)) do |_|
        raise "provider exploded"
      end

      result.strategy.should eq(Smith::Context::Strategy::Dropped)
      result.messages.first.content.first.text.not_nil!.should contain("dropped")
      result.messages.size.should be < messages.size
      assert_tool_pairing(result.messages)
    end

    it "keeps the pairing intact across a range of budgets" do
      messages = conversation(12, result_bytes: 30_000)

      [50, 500, 5_000, 50_000].each do |ceiling|
        assert_tool_pairing(compact_with_summary(messages, budget(ceiling)).messages)
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
    breakdown = Smith::Context::Breakdown.new(budget(1000))
    breakdown.add("System prompt", "x" * 400) # 100 tokens
    breakdown.add_history("Messages", [Smith::LLM::Message.user("y" * 800)])

    breakdown.total.should eq(300)
    breakdown.percent(breakdown.total).should eq(30)
    breakdown.entries.map(&.label).should eq(["System prompt", "Messages"])
  end

  it "reports everything compaction cannot touch as the overhead" do
    # This is the number handed to Context.compact, so the breakdown the user
    # reads and the decision compaction makes come from one computation.
    breakdown = Smith::Context::Breakdown.new(budget(1000))
    breakdown.add("System prompt", "x" * 400)    # 100 tokens
    breakdown.add("Tool definitions", "z" * 200) # 50 tokens
    breakdown.add_history("Messages", [Smith::LLM::Message.user("y" * 800)])

    breakdown.overhead_tokens.should eq(150)
  end

  it "reports the total as the provider will charge it" do
    breakdown = Smith::Context::Breakdown.new(budget(1000, ratio: 1.5))
    breakdown.add("System prompt", "x" * 400)

    breakdown.total.should eq(100)
    breakdown.charged_total.should eq(150)
  end

  it "keeps an empty part visible rather than hiding it" do
    # "Skills 0" answers "are skills eating my context?"; a missing line does not.
    breakdown = Smith::Context::Breakdown.new(budget(1000))
    breakdown.add("Skills", "")

    breakdown.entries.map(&.tokens).should eq([0])
  end
end

describe "compaction when the overhead alone fills the target" do
  it "aims at the ceiling rather than shredding the history to reach zero" do
    # A fat MCP tool set can leave no room at all under the target. Compacting
    # to an impossible number would throw away the whole conversation while
    # half the window sat unused.
    messages = conversation(10, result_bytes: 20_000)
    b = budget(120_000, overhead: 60_000)

    b.target_allowance.should eq(0)

    result = compact_with_summary(messages, b)

    result.after_tokens.should be <= b.max_tokens
    result.messages.size.should be > 3
    assert_tool_pairing(result.messages)
  end

  it "leaves the history alone when not even the ceiling can be reached" do
    # Nothing done to the transcript changes this, so it is not worth
    # destroying it to find out.
    messages = conversation(4, result_bytes: 20_000)
    b = budget(10_000, overhead: 50_000)

    result = compact_with_summary(messages, b)

    result.messages.should be(messages)
    result.exhausted?.should be_true
  end
end

describe "compacting a history that was already truncated once" do
  it "does not re-cut a result it has already cut" do
    # Slicing the same head again reclaims nothing, writes a "0 KiB truncated"
    # note into the transcript, and rewrites a block the provider had cached.
    messages = conversation(8, result_bytes: 20_000)
    b = budget(40_000)

    once = compact_with_summary(messages, b)
    truncated = once.messages.flat_map(&.content).select(&.type.tool_result?).first.text.not_nil!

    twice = compact_with_summary(once.messages, budget(20_000))
    again = twice.messages.flat_map(&.content).select(&.type.tool_result?).first.text.not_nil!

    again.should eq(truncated)
    again.should_not contain("0 KiB")
  end
end

# Six turns whose thinking is the bulk of the history.
private def thinking_history
  messages = [] of Smith::LLM::Message

  6.times do |i|
    messages << user_msg("request #{i}")
    messages << thinking_turn("c#{i}", "y" * 20_000, "sig-#{i}")
    messages << tool_result("c#{i}", "small")
  end

  messages
end

private def thinking_turn(id : String, thought : String, signature : String)
  Smith::LLM::Message.assistant_with_blocks([
    Smith::LLM::ContentBlock.thinking(thought, signature),
    Smith::LLM::ContentBlock.tool_use(id, "bash", JSON.parse(%({"command": "ls"}))),
  ])
end

private def named_call(id : String, name : String, args)
  Smith::LLM::Message.assistant_with_blocks([
    Smith::LLM::ContentBlock.tool_use(id, name, JSON.parse(args.to_json)),
  ])
end

# `turns` turns that all make the same call, so every result but the last says
# the same thing.
private def repeated(turns : Int32, tool : String, result_bytes : Int32)
  args = tool == "read_file" ? {"path" => "src/main.cr"} : {"command" => "make test"}
  messages = [] of Smith::LLM::Message

  turns.times do |i|
    messages << user_msg("look again #{i}")
    messages << named_call("c#{i}", tool, args)
    messages << tool_result("c#{i}", "x" * result_bytes)
  end

  messages
end

# Three small turns on the end, so the recency window does not by itself
# exceed the target — otherwise every example below would be about the
# summarizer rather than about the stage it is naming.
private def with_quiet_tail(messages)
  tail = messages.dup

  3.times do |i|
    tail << user_msg("just checking #{i}")
    tail << assistant_tool_call("tail-#{i}")
    tail << tool_result("tail-#{i}", "ok")
  end

  tail
end

private def tool_results_of(messages)
  messages.flat_map(&.content).select(&.type.tool_result?)
end

describe "stage 0 — thinking from turns that are over" do
  it "reaches the target on thinking alone, without mangling a single result" do
    # Bulky, worthless once its turn is over, and free in fidelity terms — so
    # it goes before anything lossy is considered.
    result = compact_with_summary(thinking_history, budget(20_000))

    result.stages.should eq(["thinking"])
    tool_results_of(result.messages).map(&.text).should eq(["small"] * 6)
    assert_tool_pairing(result.messages)
  end

  it "leaves the current turn byte-for-byte, signature included" do
    # Anthropic validates the signature on a thinking block; a current turn
    # that lost one is rejected outright.
    result = compact_with_summary(thinking_history, budget(20_000))

    current = result.messages[-2]
    thinking = current.content.find(&.thinking?).not_nil!
    thinking.text.not_nil!.bytesize.should eq(20_000)
    thinking.signature.should eq("sig-5")
  end

  it "keeps a message that is nothing but thinking" do
    # An assistant message with no blocks serializes to `content: null`, which
    # providers reject. No amount of reclaim is worth that.
    messages = thinking_history
    messages.insert(1, Smith::LLM::Message.assistant_with_blocks([
      Smith::LLM::ContentBlock.thinking("z" * 20_000, "sig-lonely"),
    ]))

    result = compact_with_summary(messages, budget(20_000))

    result.messages.each { |message| message.content.should_not be_empty }
  end
end

describe "stage 1 — reads a later read superseded" do
  it "reaches the target on duplicates alone, keeping the newest read in full" do
    messages = with_quiet_tail(repeated(8, "read_file", 20_000))
    result = compact_with_summary(messages, budget(45_000))

    result.stages.should eq(["duplicates"])
    assert_tool_pairing(result.messages)

    reads = tool_results_of(result.messages).first(8)
    # It stops as soon as the target is met, so not every earlier read has to
    # go — but the oldest does, and the newest never does.
    reads.first.text.not_nil!.should contain(Smith::Context::SUPERSEDED_MARKER)
    reads.last.text.not_nil!.bytesize.should eq(20_000)
  end

  it "keeps the tool_call_id and is_error of a stub, so the pairing survives" do
    messages = [] of Smith::LLM::Message
    8.times do |i|
      messages << user_msg("look again #{i}")
      messages << named_call("c#{i}", "read_file", {"path" => "src/main.cr"})
      messages << tool_result("c#{i}", "x" * 20_000, is_error: true)
    end

    result = compact_with_summary(with_quiet_tail(messages), budget(45_000))

    stub = tool_results_of(result.messages).first
    stub.tool_call_id.should eq("c0")
    stub.is_error.should be_true
  end

  it "does not treat two identical bash calls as duplicates" do
    # `make test` twice is not a duplicate, it is a before and an after —
    # collapsing the first deletes the comparison being made.
    messages = with_quiet_tail(repeated(8, "bash", 20_000))
    result = compact_with_summary(messages, budget(45_000))

    result.stages.should_not contain("duplicates")
    tool_results_of(result.messages)
      .any? { |b| b.text.not_nil!.includes?(Smith::Context::SUPERSEDED_MARKER) }
      .should be_false
  end

  it "leaves duplicates inside the recency window alone" do
    result = compact_with_summary(repeated(3, "read_file", 40_000), budget(35_000))

    result.stages.should_not contain("duplicates")
  end
end

describe "stage 2 — stale bulk" do
  it "cuts far below the old 2 KB floor" do
    # 300 stale results at the old floor is ~150k tokens, more than the whole
    # budget — the floor itself was the problem.
    messages = with_quiet_tail(conversation(10, result_bytes: 20_000))
    result = compact_with_summary(messages, budget(60_000))

    tool_results_of(result.messages).first.text.not_nil!.bytesize.should be < 2_000
    assert_tool_pairing(result.messages)
  end

  it "collapses a result it has already cut, instead of keeping its head forever" do
    # A 2 KB head kept forever is fine once; across hundreds of results it is
    # an irreducible mass larger than the whole budget. A result carries its own
    # marker, so the second pass can recognise it with no side table of state —
    # which is also what makes this survive a session round-trip through disk.
    already_cut = "x" * 2_000 + "\n\n[... 40 KiB #{Smith::Context::TRUNCATION_MARKER} ...]"

    messages = [] of Smith::LLM::Message
    20.times do |i|
      messages << user_msg("request #{i}")
      messages << assistant_tool_call("c#{i}")
      messages << tool_result("c#{i}", already_cut)
    end

    result = compact_with_summary(with_quiet_tail(messages), budget(12_000))

    stubs = tool_results_of(result.messages).select { |b| b.text.not_nil!.bytesize < 200 }
    stubs.should_not be_empty
    stubs.first.text.not_nil!.should contain(Smith::Context::TRUNCATION_MARKER)
    assert_tool_pairing(result.messages)
  end

  it "takes the largest first, so fewer results are mangled" do
    # One 200 KB result among a tail of small ones. Cutting it alone is enough;
    # oldest-first would have chewed through the small ones to get there.
    messages = [user_msg("start")]
    10.times do |i|
      messages << assistant_tool_call("small-#{i}")
      messages << tool_result("small-#{i}", "s" * 4_000)
    end
    messages << assistant_tool_call("huge")
    messages << tool_result("huge", "h" * 200_000)
    3.times { |i| messages << user_msg("later #{i}") }

    result = compact_with_summary(messages, budget(30_000))

    mangled = tool_results_of(result.messages).count do |block|
      block.text.not_nil!.includes?(Smith::Context::TRUNCATION_MARKER)
    end
    mangled.should eq(1)
  end

  it "leaves the results of the most recent turns untouched" do
    messages = with_quiet_tail(conversation(10, result_bytes: 20_000))
    result = compact_with_summary(messages, budget(60_000))

    tool_results_of(result.messages).last(3).map(&.text).should eq(["ok"] * 3)
  end

  it "gives up the window rather than send a request that cannot be accepted" do
    # One oversized `cat` inside the only turn there is. Protecting the work in
    # hand is worth less than a request the provider will take at all.
    messages = [
      user_msg("show me the file"),
      assistant_tool_call("c1"),
      tool_result("c1", "z" * 400_000),
    ]

    result = compact_with_summary(messages, budget(1_000))

    result.messages.last.content.first.text.not_nil!.should contain(Smith::Context::TRUNCATION_MARKER)
    assert_tool_pairing(result.messages)
  end
end

describe "turn boundaries the agent wrote itself" do
  it "does not let continuations consume the recency window" do
    # Three synthetic continuations inside one real turn would otherwise fill
    # the window, leaving it protecting nothing.
    messages = [] of Smith::LLM::Message
    2.times do |i|
      messages << user_msg("big request #{i}")
      messages << assistant_tool_call("big-#{i}")
      messages << tool_result("big-#{i}", "x" * 100_000)
    end
    3.times do |i|
      messages << user_msg("small request #{i}")
      messages << assistant_tool_call("recent-#{i}")
      messages << tool_result("recent-#{i}", "x" * 20_000)
    end
    3.times do |i|
      messages << Smith::LLM::Message.user("continue #{i}", synthetic: true)
      messages << assistant_tool_call("cont-#{i}")
      messages << tool_result("cont-#{i}", "x" * 5_000)
    end

    result = compact_with_summary(messages, budget(80_000))

    # The three real turns before the continuations are still protected.
    tool_results_of(result.messages)[2, 3].each do |block|
      block.text.not_nil!.bytesize.should eq(20_000)
    end
  end

  it "never summarizes up to a continuation, which would strand it" do
    messages = [] of Smith::LLM::Message
    10.times do |i|
      messages << user_msg("request #{i}")
      messages << Smith::LLM::Message.user("continue #{i}", synthetic: true)
      messages << assistant_tool_call("c#{i}")
      messages << tool_result("c#{i}", "x" * 60_000)
    end

    cut = Smith::Context.safe_cut_index(messages, 1_000)

    cut.should be > 0
    messages[cut].synthetic?.should be_false
  end
end

describe "the cost of compacting a long history" do
  it "does not re-walk the transcript once per candidate" do
    # Behavioural rather than timed: 400 tool results used to be quadratic in
    # the number of truncation candidates.
    result = compact_with_summary(conversation(400, result_bytes: 2_000), budget(50_000))

    result.compacted?.should be_true
    assert_tool_pairing(result.messages)
  end
end
