require "path"
require "file_utils"
require "./paths"

module Smith
  class ProjectContext
    FILE_NAMES = ["SMITH.md", "AGENTS.md"]

    # Discovers SMITH.md / AGENTS.md files starting from current directory up to git root/root, plus ~/.smith/
    def self.discover(start_dir : String = Dir.current) : String?
      instructions = Array(String).new

      if global = global_file
        instructions << "--- Global Instructions (#{File.basename(global)}) ---\n#{File.read(global)}"
      end

      project_files(start_dir).each do |path|
        instructions << "--- Project Instructions (#{path}) ---\n#{File.read(path)}"
      end

      return nil if instructions.empty?
      instructions.join("\n\n")
    end

    # The paths rather than the text. `smith doctor` reports *which* file a
    # run picks up, which is the question anyone asks when the instructions
    # they wrote do not seem to apply.
    def self.global_file : String?
      FILE_NAMES.each do |filename|
        path = File.join(Smith.home_dir, filename)
        return path if File.exists?(path) && File.file?(path)
      end

      nil
    end

    # One file per directory from the git root down to start_dir, outermost
    # first — the order they are laid onto the prompt in.
    def self.project_files(start_dir : String = Dir.current) : Array(String)
      path_chain = Array(String).new
      curr = File.expand_path(start_dir)

      loop do
        path_chain.unshift(curr)
        parent = File.dirname(curr)
        break if parent == curr # Reached filesystem root
        # Stop walk at git repository root boundary
        break if Smith.git_root?(curr)
        curr = parent
      end

      path_chain.compact_map do |dir|
        FILE_NAMES.map { |filename| File.join(dir, filename) }
          .find { |path| File.exists?(path) && File.file?(path) }
      end
    end
  end
end
