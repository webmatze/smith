require "path"
require "file_utils"

module Smith
  class ProjectContext
    FILE_NAMES = ["SMITH.md", "AGENTS.md"]

    # Discovers SMITH.md / AGENTS.md files starting from current directory up to git root/root, plus ~/.smith/
    def self.discover(start_dir : String = Dir.current) : String?
      instructions = Array(String).new

      # 1. Global instructions in ~/.smith/
      global_dir = ENV.fetch("SMITH_HOME", File.join(Path.home, ".smith"))
      FILE_NAMES.each do |filename|
        global_file = File.join(global_dir, filename)
        if File.exists?(global_file) && File.file?(global_file)
          instructions << "--- Global Instructions (#{filename}) ---\n#{File.read(global_file)}"
          break
        end
      end

      # 2. Local instructions walk from root to start_dir
      path_chain = Array(String).new
      curr = File.expand_path(start_dir)

      loop do
        path_chain.unshift(curr)
        parent = File.dirname(curr)
        break if parent == curr # Reached filesystem root
        # Stop walk at git repository root boundary
        break if Dir.exists?(File.join(curr, ".git"))
        curr = parent
      end

      path_chain.each do |dir|
        FILE_NAMES.each do |filename|
          local_file = File.join(dir, filename)
          if File.exists?(local_file) && File.file?(local_file)
            instructions << "--- Project Instructions (#{local_file}) ---\n#{File.read(local_file)}"
            break
          end
        end
      end

      return nil if instructions.empty?
      instructions.join("\n\n")
    end
  end
end
