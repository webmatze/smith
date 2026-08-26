require "base64"
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

# The smallest files that still carry a real signature — nothing here decodes
# an image.
PNG_FILE = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01, 0x02, 0x03]
PDF_FILE = Bytes[0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37]

private def write_bytes(dir : String, name : String, bytes : Bytes) : String
  path = File.join(dir, name)
  File.open(path, "w") { |file| file.write(bytes) }
  path
end

private def attach(path : String, tool = Smith::Tools::ReadFile.new, args = {} of String => JSON::Any)
  args["path"] = JSON::Any.new(path)
  tool.run_with_media(JSON::Any.new(args)).should_not be_nil
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

describe "read_file on an attachment" do
  it "hands back the image itself, not a refusal" do
    with_tempdir do |dir|
      path = write_bytes(dir, "shot.png", PNG_FILE)

      text, media = attach(path)

      text.should contain(path)
      text.should contain("image/png")
      text.should_not contain("looks binary")

      media.size.should eq(1)
      block = media.first
      block.type.image?.should be_true
      block.media_type.should eq("image/png")
      block.source.should eq(path)
      block.data.should_not be_nil
    end
  end

  it "reads a PDF as a document" do
    with_tempdir do |dir|
      path = write_bytes(dir, "spec.pdf", PDF_FILE)

      _, media = attach(path)

      media.first.type.document?.should be_true
      media.first.media_type.should eq("application/pdf")
    end
  end

  it "keeps the bytes out of the text-only path" do
    with_tempdir do |dir|
      path = write_bytes(dir, "shot.png", PNG_FILE)

      # `run` is what a caller with nowhere to put a block gets. It must name
      # the attachment without paying for base64 nobody asked for.
      result = read(path)

      result.should contain("image/png")
      result.should_not contain(Base64.strict_encode(PNG_FILE))
    end
  end

  it "goes by signature, not by extension" do
    with_tempdir do |dir|
      path = File.join(dir, "shot.png")
      File.write(path, "alpha\n")

      text, media = attach(path)

      media.should be_empty
      text.should eq("1: alpha\n")
    end
  end

  it "refuses one over the limit rather than shrinking it" do
    with_tempdir do |dir|
      path = write_bytes(dir, "huge.png", PNG_FILE)

      text, media = attach(path, Smith::Tools::ReadFile.new(max_media_bytes: 4))

      media.should be_empty
      text.should contain("over the")
      text.should contain("[media] max_bytes")
    end
  end

  it "says that a line range does not apply to a picture" do
    with_tempdir do |dir|
      path = write_bytes(dir, "shot.png", PNG_FILE)

      text, _ = attach(path, args: {"start_line" => JSON::Any.new(2_i64)})

      text.should contain("line range")
    end
  end
end
