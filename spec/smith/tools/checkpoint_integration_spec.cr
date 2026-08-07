require "../../spec_helper"
require "../../../src/smith/tools"
require "../../../src/smith/checkpoints"

private def with_registry(approver = Smith::Tools::AutoApprover.new, &)
  root = File.join(Dir.tempdir, "smith_cpint_#{Random::Secure.hex(4)}")
  work = File.join(root, "work")
  FileUtils.mkdir_p(work)

  store = Smith::Checkpoints::Store.new(File.join(root, "session"))
  registry = Smith::Tools::Registry.default(approver)
  registry.checkpoints = store

  begin
    yield registry, store, work
  ensure
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def write_call(path : String, content : String, id : String = "1")
  Smith::Tools::CallRequest.new(id, "write_file", JSON.parse({"path" => path, "content" => content}.to_json))
end

describe "checkpoints in the registry" do
  it "snapshots before a write and can put it back" do
    with_registry do |registry, store, work|
      path = File.join(work, "a.txt")
      File.write(path, "original")

      registry.execute_calls([write_call(path, "changed")]).first.is_error.should be_false
      File.read(path).should eq("changed")

      store.list.size.should eq(1)
      store.rewind_to(store.list.first)
      File.read(path).should eq("original")
    end
  end

  it "records what smith left, so a later external change is noticed" do
    with_registry do |registry, store, work|
      path = File.join(work, "a.txt")
      File.write(path, "original")
      registry.execute_calls([write_call(path, "changed")])

      store.list.first.after_digest.should_not be_nil
    end
  end

  it "does not snapshot a call the approver refused" do
    with_registry(approver: Smith::Tools::DenyApprover.new) do |registry, store, work|
      path = File.join(work, "a.txt")
      File.write(path, "original")

      registry.execute_calls([write_call(path, "changed")]).first.is_error.should be_true

      store.list.should be_empty
      File.read(path).should eq("original")
    end
  end

  it "does not snapshot a read-only call" do
    with_registry do |registry, store, work|
      path = File.join(work, "a.txt")
      File.write(path, "original")

      registry.execute_calls([
        Smith::Tools::CallRequest.new("1", "read_file", JSON.parse({"path" => path}.to_json)),
      ])

      store.list.should be_empty
    end
  end

  it "snapshots the rewritten path when a hook redirected the call" do
    with_registry do |registry, store, work|
      original = File.join(work, "a.txt")
      redirected = File.join(work, "b.txt")
      File.write(original, "a")
      File.write(redirected, "b")

      registry.hooks = Smith::Hooks::Runner.new(
        [Smith::Hooks::Definition.new(
          event: Smith::Hooks::Event::PreToolUse,
          command: %(echo '{"updated_input":{"path":"#{redirected}","content":"rewritten"}}'),
        )],
        warn_io: IO::Memory.new
      )

      registry.execute_calls([write_call(original, "changed")])

      # The snapshot has to follow the call that actually ran, not the one the
      # model asked for.
      store.list.first.path.should eq(redirected)
      store.rewind_to(store.list.first)
      File.read(redirected).should eq("b")
    end
  end
end
