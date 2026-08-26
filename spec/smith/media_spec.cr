require "../spec_helper"
require "file_utils"
require "../../src/smith/media"

# The smallest byte strings that still carry a real signature. Nothing here
# decodes an image, so a valid header and arbitrary tail is the whole file a
# detector needs to see.
PNG_BYTES  = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01, 0x02, 0x03]
JPEG_BYTES = Bytes[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46]
GIF_BYTES  = Bytes[0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00]
WEBP_BYTES = Bytes[0x52, 0x49, 0x46, 0x46, 0x1A, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50]
PDF_BYTES  = Bytes[0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37]

private def with_file(bytes : Bytes, name : String = "file", &)
  dir = File.join(Dir.tempdir, "smith_media_#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(dir)
  path = File.join(dir, name)
  File.open(path, "w") { |file| file.write(bytes) }
  begin
    yield path
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe Smith::Media do
  describe ".detect" do
    it "recognises every format it claims to support" do
      Smith::Media.detect(PNG_BYTES).should eq(Smith::Media::PNG)
      Smith::Media.detect(JPEG_BYTES).should eq(Smith::Media::JPEG)
      Smith::Media.detect(GIF_BYTES).should eq(Smith::Media::GIF)
      Smith::Media.detect(WEBP_BYTES).should eq(Smith::Media::WEBP)
      Smith::Media.detect(PDF_BYTES).should eq(Smith::Media::PDF)
    end

    it "sorts images from documents" do
      Smith::Media::PNG.kind.should eq(Smith::Media::Kind::Image)
      Smith::Media::PDF.kind.should eq(Smith::Media::Kind::Document)
    end

    it "refuses an unknown binary rather than guessing a media type" do
      Smith::Media.detect(Bytes[0x00, 0x01, 0x02, 0x03, 0x04, 0x05]).should be_nil
    end

    it "does not mistake a bare RIFF container for WebP" do
      # A WAV file: same first four bytes, different form type.
      wav = Bytes[0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45]
      Smith::Media.detect(wav).should be_nil
    end

    it "says nothing about text" do
      Smith::Media.detect("hello, world".to_slice).should be_nil
    end

    it "does not read past the end of a short file" do
      Smith::Media.detect(Bytes[0x52, 0x49]).should be_nil
      Smith::Media.detect(Bytes.empty).should be_nil
    end
  end

  describe ".detect_file" do
    it "goes by the bytes, not by the extension" do
      with_file(PNG_BYTES, "screenshot.txt") do |path|
        Smith::Media.detect_file(path).should eq(Smith::Media::PNG)
      end
    end

    it "does not take a text file for an image because of its name" do
      with_file("just words".to_slice, "screenshot.png") do |path|
        Smith::Media.detect_file(path).should be_nil
      end
    end
  end

  describe ".read" do
    it "encodes the file and reports its size before encoding" do
      with_file(PNG_BYTES) do |path|
        attachment = Smith::Media.read(path).should_not be_nil

        attachment.media_type.should eq("image/png")
        attachment.image?.should be_true
        attachment.bytes.should eq(PNG_BYTES.size)
        Base64.decode(attachment.data).should eq(PNG_BYTES)
      end
    end

    it "returns nothing for a file it would not attach" do
      with_file("plain text".to_slice) do |path|
        Smith::Media.read(path).should be_nil
      end
    end
  end

  describe ".human_size" do
    it "stays readable across the range a skip message has to report" do
      Smith::Media.human_size(512).should eq("512 B")
      Smith::Media.human_size(400 * 1024).should eq("400 KB")
      Smith::Media.human_size(3 * 1024 * 1024).should eq("3.0 MB")
    end
  end
end
