require "../spec_helper"
require "file_utils"
require "../../src/smith/agent"
require "../../src/smith/context"
require "../../src/smith/session"
require "../../src/smith/output"

# Records the request it was handed, so a spec can look at what the agent
# actually decided to send.
private class RecordingProvider < Smith::LLM::Provider
  getter last : Smith::LLM::Request? = nil

  def initialize(@images : Bool = true, @documents : Bool = true)
  end

  def name : String
    "recorder"
  end

  def default_model : String
    "recorder-model"
  end

  def supports_images? : Bool
    @images
  end

  def supports_documents? : Bool
    @documents
  end

  def complete(request : Smith::LLM::Request) : Smith::LLM::Response
    @last = request
    Smith::LLM::Response.new("r1", request.model, [Smith::LLM::ContentBlock.text("done")])
  end
end

# `Request` is handed the agent's live message array, so by the time a spec
# looks at it the assistant reply has been appended too. The user turn is the
# first message, not the last.
private def agent_for(provider)
  Smith::Agent.new(provider: provider, registry: Smith::Tools::Registry.new, model: "recorder-model")
end

private def image_block(source : String = "shot.png")
  Smith::LLM::ContentBlock.image("image/png", "QUJD", source)
end

private def user_message(blocks : Array(Smith::LLM::ContentBlock))
  Smith::LLM::Message.new(Smith::LLM::Role::User, blocks)
end

describe "attachments reaching a provider" do
  it "hangs them off the user message, after the prompt" do
    provider = RecordingProvider.new
    agent_for(provider).send("what is wrong here?", [image_block] of Smith::LLM::ContentBlock)

    content = provider.last.should_not(be_nil).messages.first.content
    content.size.should eq(2)
    content[0].type.text?.should be_true
    content[1].type.image?.should be_true
  end

  it "describes an image the provider cannot take, rather than dropping it" do
    provider = RecordingProvider.new(images: false)
    agent_for(provider).send("look", [image_block] of Smith::LLM::ContentBlock)

    content = provider.last.should_not(be_nil).messages.first.content
    content.size.should eq(2)
    content[1].type.text?.should be_true
    note = content[1].text.should_not be_nil
    note.should contain("shot.png")
    note.should contain("cannot receive images")
  end

  it "points at an external tool for a PDF the provider cannot read" do
    provider = RecordingProvider.new(documents: false)
    block = Smith::LLM::ContentBlock.document("application/pdf", "JVBERi0=", "paper.pdf")
    agent_for(provider).send("summarise", [block] of Smith::LLM::ContentBlock)

    text = provider.last.should_not(be_nil).messages.first.content[1].text.should_not be_nil
    text.should contain("paper.pdf")
    text.should contain("pdftotext")
  end
end

describe "attachments in the context estimate" do
  it "grows with every attachment, though the block carries no text" do
    bare = [user_message([Smith::LLM::ContentBlock.text("hi")])]
    with_image = [user_message([Smith::LLM::ContentBlock.text("hi"), image_block])]

    Smith::Context.estimate_tokens(with_image).should eq(
      Smith::Context.estimate_tokens(bare) + Smith::Context::IMAGE_TOKENS
    )
  end

  it "charges a PDF more than an image, because it usually is" do
    document = [user_message([Smith::LLM::ContentBlock.document("application/pdf", "JVBERi0=", "p.pdf")])]
    image = [user_message([image_block])]

    Smith::Context.estimate_tokens(document).should be > Smith::Context.estimate_tokens(image)
  end
end

describe "attachments under compaction" do
  it "replaces one from a finished turn with a note that names it" do
    # Six real turns, so the first is well outside the three-turn window, and
    # a budget small enough that compaction has to act.
    messages = [] of Smith::LLM::Message
    messages << user_message([Smith::LLM::ContentBlock.text("first"), image_block("old.png")])
    5.times do |index|
      messages << Smith::LLM::Message.user("turn #{index}")
      messages << Smith::LLM::Message.assistant("answer #{index}")
    end

    budget = Smith::Context::Budget.new(max_tokens: 2_000)
    result = Smith::Context.compact(messages, budget) { "a summary" }

    first = result.messages.first
    first.content.any?(&.media?).should be_false
    first.content.map(&.text).compact.join(" ").should contain("old.png")
    # Not an empty message: providers reject one, and the model would be left
    # with a hole it cannot see.
    first.content.should_not be_empty
    result.stages.should contain("attachments")
  end

  it "leaves an attachment in the current turn alone" do
    messages = [user_message([Smith::LLM::ContentBlock.text("look"), image_block("fresh.png")])]
    budget = Smith::Context::Budget.new(max_tokens: 2_000)

    result = Smith::Context.compact(messages, budget) { "a summary" }

    result.messages.first.content.any?(&.media?).should be_true
  end
end

describe "attachments and persistence" do
  it "round-trips the bytes without putting them in session.json" do
    dir = File.join(Dir.tempdir, "smith_media_session_#{Random::Secure.hex(4)}")

    begin
      store = Smith::Session::Store.new(base_dir: dir)
      session = store.create(model: "m", provider: "recorder")
      session.messages << user_message([Smith::LLM::ContentBlock.text("look"), image_block])
      store.save(session)

      raw = File.read(File.join(store.session_dir(session.id), "session.json"))
      raw.should_not contain("QUJD")
      raw.should contain("image/png")

      loaded = store.load(session.id)
      block = loaded.messages.last.content.last
      block.type.image?.should be_true
      block.data.should eq("QUJD")
      block.media_type.should eq("image/png")
      block.source.should eq("shot.png")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "keeps the attachment reachable from a fork, which has its own directory" do
    dir = File.join(Dir.tempdir, "smith_media_fork_#{Random::Secure.hex(4)}")

    begin
      store = Smith::Session::Store.new(base_dir: dir)
      session = store.create(model: "m", provider: "recorder")
      session.messages << user_message([Smith::LLM::ContentBlock.text("look"), image_block])
      store.save(session)

      copy = store.fork(session.id)
      store.load(copy.id).messages.last.content.last.data.should eq("QUJD")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "opens a session whose attachment file is gone, without its bytes" do
    dir = File.join(Dir.tempdir, "smith_media_missing_#{Random::Secure.hex(4)}")

    begin
      store = Smith::Session::Store.new(base_dir: dir)
      session = store.create(model: "m", provider: "recorder")
      session.messages << user_message([Smith::LLM::ContentBlock.text("look"), image_block])
      store.save(session)
      FileUtils.rm_rf(store.media_dir(session.id))

      block = store.load(session.id).messages.last.content.last
      block.data.should be_nil
      block.media_type.should eq("image/png")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "keeps the base64 out of the raw transcript log too" do
    dir = File.join(Dir.tempdir, "smith_media_log_#{Random::Secure.hex(4)}")

    begin
      FileUtils.mkdir_p(dir)
      log = Smith::TranscriptLog.new(dir, warn_io: IO::Memory.new)
      log.append([user_message([Smith::LLM::ContentBlock.text("look"), image_block])])

      File.read(log.path).should_not contain("QUJD")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end

describe "attachments in the output" do
  it "names the file and its size, never the payload" do
    io = IO::Memory.new
    renderer = Smith::Output::HumanRenderer.new(io)
    embedded = Smith::Mentions::Embedded.new("shot.png", 0, media_type: "image/png", bytes: 412 * 1024)

    renderer.handle(Smith::Events::FilesMentioned.new([embedded], [] of Smith::Mentions::Skip))

    io.to_s.should contain("shot.png")
    io.to_s.should contain("image/png")
    io.to_s.should contain("412 KB")
  end

  it "emits metadata into the JSON stream and no base64" do
    io = IO::Memory.new
    renderer = Smith::Output::JsonRenderer.new(io, IO::Memory.new)
    embedded = Smith::Mentions::Embedded.new("shot.png", 0, media_type: "image/png", bytes: 1024)

    renderer.handle(Smith::Events::FilesMentioned.new([embedded], [] of Smith::Mentions::Skip))

    line = JSON.parse(io.to_s.lines.first)
    line["files"][0]["media_type"].should eq("image/png")
    line["files"][0]["bytes"].should eq(1024)
  end
end

# A tool that answers with a picture, so the agent path can be exercised
# without a real file on disk.
private class PictureTool < Smith::Tools::Tool
  include Smith::Tools::ParallelTool

  def name : String
    "picture"
  end

  def description : String
    "Returns a picture."
  end

  def parameters : JSON::Any
    JSON.parse(%({"type": "object", "properties": {}}))
  end

  def run(args : JSON::Any) : String
    "Attached 'shot.png' as image/png (3 B)."
  end

  def run_with_media(args : JSON::Any) : Tuple(String, Array(Smith::LLM::ContentBlock))?
    {run(args), [Smith::LLM::ContentBlock.image("image/png", "QUJD", "shot.png")]}
  end
end

# Asks for the picture once, then finishes.
private class PictureCaller < Smith::LLM::Provider
  getter requests = Array(Smith::LLM::Request).new

  def initialize(@tool_result_media : Bool = false)
  end

  def name : String
    "picture-caller"
  end

  def default_model : String
    "picture-model"
  end

  def supports_tool_result_media? : Bool
    @tool_result_media
  end

  def complete(request : Smith::LLM::Request) : Smith::LLM::Response
    @requests << request

    if @requests.size == 1
      Smith::LLM::Response.new("r1", request.model, [
        Smith::LLM::ContentBlock.tool_use("p1", "picture", JSON.parse("{}")),
      ])
    else
      Smith::LLM::Response.new("r2", request.model, [Smith::LLM::ContentBlock.text("a red button")])
    end
  end
end

private def picture_agent(provider)
  registry = Smith::Tools::Registry.new
  registry.register(PictureTool.new)
  Smith::Agent.new(provider: provider, registry: registry, model: "picture-model")
end

describe "an attachment a tool produced" do
  it "reaches a provider that can take one, beside its result" do
    provider = PictureCaller.new(tool_result_media: true)
    agent = picture_agent(provider)
    agent.send("what colour is the button?")

    tool_turn = provider.requests.last.messages.find! { |message| message.role.tool? }
    tool_turn.content.size.should eq(2)
    tool_turn.content[0].type.tool_result?.should be_true
    tool_turn.content[1].type.image?.should be_true
    # The id is what lets the provider adapter fold the two back together.
    tool_turn.content[1].tool_call_id.should eq("p1")
  end

  it "becomes a line in the result for a provider that cannot" do
    provider = PictureCaller.new(tool_result_media: false)
    agent = picture_agent(provider)
    agent.send("what colour is the button?")

    tool_turn = provider.requests.last.messages.find! { |message| message.role.tool? }
    tool_turn.content.size.should eq(1)

    text = tool_turn.content.first.text.not_nil!
    text.should contain("shot.png")
    text.should contain("picture-caller")
    text.should contain("cannot receive an image")
  end

  it "reports the call once, whatever came back with it" do
    provider = PictureCaller.new(tool_result_media: true)
    agent = picture_agent(provider)

    finished = 0
    agent.on_event do |event|
      finished += 1 if event.is_a?(Smith::Events::ToolFinished)
    end
    agent.send("what colour is the button?")

    finished.should eq(1)
  end
end

describe "an attachment a tool produced, under compaction" do
  it "leaves the note where the result is, not beside it" do
    id = "t1"
    tool_turn = Smith::LLM::Message.new(Smith::LLM::Role::Tool, [
      Smith::LLM::ContentBlock.tool_result(id, "Attached 'old.png' as image/png (3 B)."),
      Smith::LLM::ContentBlock.new(
        Smith::LLM::ContentBlock::BlockType::Image,
        tool_call_id: id,
        media_type: "image/png",
        data: "QUJD",
        source: "old.png"
      ),
    ])

    messages = [Smith::LLM::Message.user("look"), tool_turn] of Smith::LLM::Message
    5.times do |index|
      messages << Smith::LLM::Message.user("turn #{index}")
      messages << Smith::LLM::Message.assistant("answer #{index}")
    end

    budget = Smith::Context::Budget.new(max_tokens: 2_000)
    result = Smith::Context.compact(messages, budget) { "a summary" }

    compacted = result.messages.find! { |message| message.role.tool? }
    # No stray text block: under role tool every adapter keeps only
    # tool_result blocks, so a note beside one would vanish with the image.
    compacted.content.size.should eq(1)
    compacted.content.first.type.tool_result?.should be_true
    compacted.content.first.tool_call_id.should eq(id)
    compacted.content.first.text.not_nil!.should contain("old.png")
    result.stages.should contain("attachments")
  end
end
