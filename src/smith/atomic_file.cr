require "file_utils"

module Smith
  class AtomicFile
    # Writes content atomically using a temporary file in the target directory, then renames it into place.
    def self.write(path : String, content : String, mode : Int32 = 0o600)
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir, mode: 0o700) unless Dir.exists?(dir)

      temp_path = "#{path}.tmp.#{Random::Secure.hex(4)}"

      begin
        File.open(temp_path, "w", perm: File::Permissions.new(mode)) do |file|
          file.write(content.to_slice)
        end
        File.rename(temp_path, path)
      ensure
        File.delete(temp_path) if File.exists?(temp_path)
      end
    end
  end
end
