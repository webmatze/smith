require "../spec_helper"
require "../../src/smith/checkpoints"

private def with_store(enabled : Bool = true, &)
  root = File.join(Dir.tempdir, "smith_cp_#{Random::Secure.hex(4)}")
  work = File.join(root, "work")
  FileUtils.mkdir_p(work)
  begin
    yield Smith::Checkpoints::Store.new(File.join(root, "session"), enabled: enabled), work
  ensure
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def write_args(path : String, content : String = "new")
  JSON.parse({"path" => path, "content" => content}.to_json)
end

# Mimics a tool call: snapshot, change the file, then record what smith left.
private def simulate(store, tool : String, path : String, new_content : String?, message_index : Int32 = 0)
  store.current_message_index = message_index
  entry = store.snapshot(tool, write_args(path))

  if new_content.nil?
    File.delete(path) if File.exists?(path)
  else
    File.write(path, new_content)
  end

  store.seal(entry) if entry
  entry
end

describe Smith::Checkpoints::Store do
  it "records nothing when disabled" do
    with_store(enabled: false) do |store, work|
      path = File.join(work, "a.txt")
      File.write(path, "before")

      store.snapshot("write_file", write_args(path)).should be_nil
      store.list.should be_empty
    end
  end

  it "records nothing for a tool that does not touch a known path" do
    with_store do |store, _work|
      store.snapshot("bash", JSON.parse(%({"command": "ls"}))).should be_nil
      store.snapshot("read_file", JSON.parse(%({"path": "/x"}))).should be_nil
    end
  end

  it "snapshots an existing file and restores it exactly" do
    with_store do |store, work|
      path = File.join(work, "a.txt")
      File.write(path, "original\ncontent\n")

      simulate(store, "write_file", path, "clobbered")
      File.read(path).should eq("clobbered")

      result = store.rewind_to(store.list.first)

      result.restored.should eq([path])
      File.read(path).should eq("original\ncontent\n")
    end
  end

  it "deletes a file the run created" do
    with_store do |store, work|
      path = File.join(work, "new.txt")

      simulate(store, "write_file", path, "created")
      File.exists?(path).should be_true

      result = store.rewind_to(store.list.first)

      result.deleted.should eq([path])
      File.exists?(path).should be_false
    end
  end

  it "stores one blob for repeated identical content" do
    with_store do |store, work|
      a = File.join(work, "a.txt")
      b = File.join(work, "b.txt")
      File.write(a, "same")
      File.write(b, "same")

      simulate(store, "write_file", a, "x")
      simulate(store, "write_file", b, "y")

      store.list.size.should eq(2)
      store.blob_count.should eq(1)
    end
  end

  it "rewinds several checkpoints at once, back to the oldest state" do
    with_store do |store, work|
      path = File.join(work, "a.txt")
      File.write(path, "v1")

      simulate(store, "edit_file", path, "v2")
      simulate(store, "edit_file", path, "v3")

      store.rewind_to(store.list.first)

      File.read(path).should eq("v1")
    end
  end

  it "rewinds only from the chosen checkpoint onwards" do
    with_store do |store, work|
      path = File.join(work, "a.txt")
      File.write(path, "v1")

      simulate(store, "edit_file", path, "v2")
      simulate(store, "edit_file", path, "v3")

      store.rewind_to(store.list.last)

      File.read(path).should eq("v2")
    end
  end
end

describe "an external change since the snapshot" do
  it "is reported instead of silently overwritten" do
    with_store do |store, work|
      path = File.join(work, "a.txt")
      File.write(path, "original")

      simulate(store, "write_file", path, "by smith")
      File.write(path, "by the user, afterwards")

      result = store.rewind_to(store.list.first)

      result.conflicts.should eq([path])
      result.restored.should be_empty
      File.read(path).should eq("by the user, afterwards")
    end
  end

  it "is overwritten only when explicitly forced" do
    with_store do |store, work|
      path = File.join(work, "a.txt")
      File.write(path, "original")

      simulate(store, "write_file", path, "by smith")
      File.write(path, "by the user, afterwards")

      result = store.rewind_to(store.list.first, force: true)

      result.restored.should eq([path])
      File.read(path).should eq("original")
    end
  end

  it "counts a file deleted outside smith as a conflict too" do
    with_store do |store, work|
      path = File.join(work, "a.txt")
      File.write(path, "original")

      simulate(store, "write_file", path, "by smith")
      File.delete(path)

      store.rewind_to(store.list.first).conflicts.should eq([path])
    end
  end

  it "changes nothing under dry_run" do
    with_store do |store, work|
      path = File.join(work, "a.txt")
      File.write(path, "original")
      simulate(store, "write_file", path, "by smith")

      result = store.rewind_to(store.list.first, dry_run: true)

      result.restored.should eq([path])
      File.read(path).should eq("by smith")
      store.list.size.should eq(1), "a dry run discarded the checkpoint"
    end
  end
end

describe "checkpoint bookkeeping" do
  it "remembers the transcript position at the time of the call" do
    with_store do |store, work|
      path = File.join(work, "a.txt")
      File.write(path, "x")

      simulate(store, "write_file", path, "y", message_index: 7)

      store.list.first.message_index.should eq(7)
    end
  end

  it "numbers checkpoints in order and survives a reopen" do
    with_store do |store, work|
      path = File.join(work, "a.txt")
      File.write(path, "x")
      simulate(store, "write_file", path, "y")
      simulate(store, "write_file", path, "z")

      reopened = Smith::Checkpoints::Store.new(store.session_dir)
      reopened.list.map(&.sequence).should eq([1, 2])
      # Numbering continues rather than restarting.
      File.write(path, "z")
      simulate(reopened, "write_file", path, "w")
      reopened.list.map(&.sequence).should eq([1, 2, 3])
    end
  end

  it "drops the oldest beyond the per-session limit" do
    with_store do |store, work|
      path = File.join(work, "a.txt")
      5.times do |i|
        File.write(path, "v#{i}")
        simulate(store, "write_file", path, "next")
      end

      store.prune(max: 2, retention: 30.days)

      store.list.map(&.sequence).should eq([4, 5])
    end
  end

  it "drops anything past its retention, and the blobs with it" do
    with_store do |store, work|
      path = File.join(work, "a.txt")
      File.write(path, "x")
      simulate(store, "write_file", path, "y")

      store.prune(max: 100, retention: Time::Span.zero)

      store.list.should be_empty
      store.blob_count.should eq(0)
    end
  end

  it "keeps a blob that another checkpoint still needs" do
    with_store do |store, work|
      a = File.join(work, "a.txt")
      b = File.join(work, "b.txt")
      File.write(a, "same")
      File.write(b, "same")
      simulate(store, "write_file", a, "x")
      simulate(store, "write_file", b, "y")

      store.prune(max: 1, retention: 30.days)

      store.list.size.should eq(1)
      store.blob_count.should eq(1)
      store.rewind_to(store.list.first).restored.should eq([b])
      File.read(b).should eq("same")
    end
  end
end

describe "a rewind that could not finish" do
  # The conflict message tells the user to re-run with --force. That only
  # works if the checkpoints are still there to re-run against.
  it "keeps the checkpoints so --force still has something to work with" do
    with_store do |store, work|
      path = File.join(work, "a.txt")
      File.write(path, "original")
      simulate(store, "write_file", path, "by smith")
      File.write(path, "by the user")

      first = store.rewind_to(store.list.first)
      first.applied?.should be_false
      store.list.size.should eq(1), "the checkpoint was discarded despite the conflict"

      second = store.rewind_to(store.list.first, force: true)
      second.applied?.should be_true
      File.read(path).should eq("original")
      store.list.should be_empty
    end
  end

  it "reports a clean rewind as applied" do
    with_store do |store, work|
      path = File.join(work, "a.txt")
      File.write(path, "original")
      simulate(store, "write_file", path, "by smith")

      store.rewind_to(store.list.first).applied?.should be_true
    end
  end

  it "leaves the checkpoints alone after a dry run, applied or not" do
    with_store do |store, work|
      path = File.join(work, "a.txt")
      File.write(path, "original")
      simulate(store, "write_file", path, "by smith")

      store.rewind_to(store.list.first, dry_run: true).applied?.should be_true
      store.list.size.should eq(1)
    end
  end
end

describe "how far a rewind goes" do
  # Undoing one step is what "undo" means everywhere else, and it is what the
  # issue specifies as the default. Rolling the whole session back by accident
  # is the expensive direction to get wrong.
  it "undoes only the newest checkpoint by default" do
    with_store do |store, work|
      path = File.join(work, "a.txt")
      File.write(path, "v1")
      simulate(store, "edit_file", path, "v2")
      simulate(store, "edit_file", path, "v3")

      store.rewind_to(store.default_target.not_nil!)

      File.read(path).should eq("v2")
      # The earlier checkpoint survives, so a second rewind goes back further.
      store.list.map(&.sequence).should eq([1])
    end
  end

  it "walks all the way back one step at a time" do
    with_store do |store, work|
      path = File.join(work, "a.txt")
      File.write(path, "v1")
      simulate(store, "edit_file", path, "v2")
      simulate(store, "edit_file", path, "v3")

      store.rewind_to(store.default_target.not_nil!)
      store.rewind_to(store.default_target.not_nil!)

      File.read(path).should eq("v1")
      store.list.should be_empty
    end
  end

  it "reaches everything from an explicit target onwards" do
    with_store do |store, work|
      path = File.join(work, "a.txt")
      File.write(path, "v1")
      simulate(store, "edit_file", path, "v2")
      simulate(store, "edit_file", path, "v3")

      # --to 1 means "back to the state before checkpoint 1".
      store.rewind_to(store.list.first)

      File.read(path).should eq("v1")
    end
  end

  it "has no target when there is nothing to undo" do
    with_store do |store, _work|
      store.default_target.should be_nil
    end
  end
end
