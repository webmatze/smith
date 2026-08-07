require "../spec_helper"
require "../../src/smith/trust"

private def with_store(&)
  temp_dir = File.join(Dir.tempdir, "smith_trust_#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(temp_dir)
  begin
    yield Smith::TrustStore.new(temp_dir), temp_dir
  ensure
    FileUtils.rm_rf(temp_dir) if Dir.exists?(temp_dir)
  end
end

describe Smith::TrustStore do
  it "trusts nothing by default" do
    with_store do |store, _dir|
      store.trusted?("/some/project", "abc").should be_false
    end
  end

  it "remembers a granted trust across instances" do
    with_store do |store, dir|
      store.trust("/some/project", "abc")

      Smith::TrustStore.new(dir).trusted?("/some/project", "abc").should be_true
    end
  end

  it "asks again once the hook section changed" do
    with_store do |store, _dir|
      store.trust("/some/project", "abc")

      store.trusted?("/some/project", "def").should be_false
    end
  end

  it "keeps trust scoped to the project it was granted for" do
    with_store do |store, _dir|
      store.trust("/project-a", "abc")

      store.trusted?("/project-b", "abc").should be_false
    end
  end

  it "replaces the entry rather than appending when trust is re-granted" do
    with_store do |store, dir|
      store.trust("/some/project", "abc")
      store.trust("/some/project", "def")

      reopened = Smith::TrustStore.new(dir)
      reopened.trusted?("/some/project", "abc").should be_false
      reopened.trusted?("/some/project", "def").should be_true
    end
  end

  it "survives a corrupt store file instead of taking smith down" do
    with_store do |store, dir|
      File.write(File.join(dir, "trusted.json"), "{ not json")

      reopened = Smith::TrustStore.new(dir)
      reopened.trusted?("/some/project", "abc").should be_false
      reopened.trust("/some/project", "abc")
      reopened.trusted?("/some/project", "abc").should be_true
    end
  end
end

describe Smith::TrustPrompt do
  it "grants trust on an explicit yes and remembers it" do
    with_store do |store, _dir|
      output = IO::Memory.new
      prompt = Smith::TrustPrompt.new(store, input: IO::Memory.new("y\n"), output: output)

      prompt.allow?("/some/project", "abc", ["format.sh"]).should be_true
      store.trusted?("/some/project", "abc").should be_true
      output.to_s.should contain("format.sh")
    end
  end

  it "refuses on anything but yes, and does not remember a refusal" do
    with_store do |store, _dir|
      prompt = Smith::TrustPrompt.new(store, input: IO::Memory.new("n\n"), output: IO::Memory.new)

      prompt.allow?("/some/project", "abc", ["format.sh"]).should be_false
      store.trusted?("/some/project", "abc").should be_false
    end
  end

  it "refuses on EOF — there is nobody to ask" do
    with_store do |store, _dir|
      prompt = Smith::TrustPrompt.new(store, input: IO::Memory.new(""), output: IO::Memory.new)

      prompt.allow?("/some/project", "abc", ["format.sh"]).should be_false
    end
  end

  it "does not ask again once trusted" do
    with_store do |store, _dir|
      store.trust("/some/project", "abc")
      output = IO::Memory.new
      prompt = Smith::TrustPrompt.new(store, input: IO::Memory.new(""), output: output)

      prompt.allow?("/some/project", "abc", ["format.sh"]).should be_true
      output.to_s.should be_empty
    end
  end

  it "grants trust up front when the user passed --trust-hooks" do
    with_store do |store, _dir|
      output = IO::Memory.new
      prompt = Smith::TrustPrompt.new(store, input: IO::Memory.new(""), output: output, preapproved: true)

      prompt.allow?("/some/project", "abc", ["format.sh"]).should be_true
      store.trusted?("/some/project", "abc").should be_true
      output.to_s.should be_empty
    end
  end
end
