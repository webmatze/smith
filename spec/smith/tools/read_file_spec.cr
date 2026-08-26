require "file_utils"
require "../../spec_helper"
require "../../../src/smith/tools"

private def with_tempdir(&)
  dir = File.join(Dir.tempdir, "smith-read-file-#{Random.rand(100_000)}")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def read(path : String, args = {} of String => JSON::Any) : String
  args["path"] = JSON::Any.new(path)
  Smith::Tools::ReadFile.new.run(JSON::Any.new(args))
end

describe Smith::Tools::ReadFile do
  it "numbers the lines of a text file" do
    with_tempdir do |dir|
      path = File.join(dir, "notes.md")
      File.write(path, "alpha\nbeta\n")

      read(path).should eq("1: alpha\n2: beta\n")
    end
  end

  it "honours a line range" do
    with_tempdir do |dir|
      path = File.join(dir, "notes.md")
      File.write(path, "a\nb\nc\nd\n")

      result = read(path, {
        "start_line" => JSON::Any.new(2_i64),
        "end_line"   => JSON::Any.new(3_i64),
      })

      result.should eq("2: b\n3: c\n")
    end
  end

  it "refuses a binary file instead of reading it" do
    with_tempdir do |dir|
      path = File.join(dir, "pixel.png")
      File.write(path, Bytes[0x89, 0x50, 0x4E, 0x47, 0x00, 0x0D, 0x0A, 0x1A])

      result = read(path)

      result.should contain("looks binary")
      result.should contain(path)
      result.should contain("bash")
      result.valid_encoding?.should be_true
      result.should_not contain("PNG")
    end
  end

  it "goes by content, not by extension" do
    with_tempdir do |dir|
      path = File.join(dir, "log.txt")
      File.write(path, "header\u0000trailer\n")

      read(path).should contain("looks binary")
    end
  end

  it "does not call an empty file binary" do
    with_tempdir do |dir|
      path = File.join(dir, "empty.txt")
      File.write(path, "")

      read(path).should_not contain("looks binary")
    end
  end

  it "reports a missing file" do
    read(File.join(Dir.tempdir, "smith-absent-#{Random.rand(100_000)}"))
      .should contain("does not exist")
  end

  it "reports a directory" do
    with_tempdir do |dir|
      read(dir).should contain("is a directory")
    end
  end

  it "truncates at the byte cap" do
    with_tempdir do |dir|
      path = File.join(dir, "big.txt")
      File.open(path, "w") do |file|
        20_000.times { |i| file.puts "#{i}: #{"x" * 40}" }
      end

      result = read(path)

      result.should contain("Content truncated at 256 KiB limit")
      result.bytesize.should be < Smith::Tools::ReadFile::MAX_BYTES + 128
    end
  end
end
