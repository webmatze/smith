require "json"
require "file_utils"
require "./atomic_file"
require "./paths"

module Smith
  # Which project configs the user has allowed to run hooks.
  #
  # Hooks are arbitrary commands run with the user's rights and outside the
  # approval gate, so a `.smith/config.toml` checked into someone else's
  # repository is a code-execution vector. Trust is granted per project *and*
  # per hook section: change the hooks, and smith asks again.
  class TrustStore
    FILE_NAME = "trusted.json"

    getter path : String

    @entries : Hash(String, String)

    def initialize(base_dir : String? = nil)
      dir = base_dir || Smith.home_dir
      FileUtils.mkdir_p(dir, mode: 0o700)
      @path = File.join(dir, FILE_NAME)
      @entries = load_entries
    end

    def trusted?(project_path : String, digest : String) : Bool
      @entries[project_path]? == digest
    end

    def trust(project_path : String, digest : String) : Nil
      @entries[project_path] = digest
      AtomicFile.write(@path, @entries.to_json)
    end

    # A corrupt store must not stop smith from starting; it degrades to
    # "nothing is trusted", which is the safe direction.
    private def load_entries : Hash(String, String)
      return Hash(String, String).new unless File.exists?(@path)

      begin
        Hash(String, String).from_json(File.read(@path))
      rescue
        Hash(String, String).new
      end
    end
  end

  # Asks once, then remembers. Deliberately separate from Tools::Approver:
  # `--yes` waives approval for tools the model chose, which is not the same as
  # waiving it for code a repository brought with it. Only the explicit
  # `--trust-hooks` does that.
  class TrustPrompt
    # Exposed for UI subclasses that ask in their own way.
    protected getter store : TrustStore
    protected getter? preapproved : Bool

    def initialize(
      @store : TrustStore,
      @input : IO = STDIN,
      @output : IO = STDOUT,
      @preapproved : Bool = false,
    )
    end

    def allow?(project_path : String, digest : String, commands : Array(String)) : Bool
      return true if @store.trusted?(project_path, digest)

      if @preapproved
        @store.trust(project_path, digest)
        return true
      end

      return false unless ask(project_path, commands)

      @store.trust(project_path, digest)
      true
    end

    private def ask(project_path : String, commands : Array(String)) : Bool
      @output.puts "\n\e[33m⚠️  This project defines hooks\e[0m"
      @output.puts "   #{project_path}"
      @output.puts "   Hooks run shell commands with your permissions and do not pass the approval gate:"
      commands.each { |command| @output.puts "     • #{command}" }
      @output.print "   Trust this project's hooks? [y]es / [N]o: "
      @output.flush

      answer = @input.gets
      # EOF — nobody is there to answer, so refuse.
      return false if answer.nil?

      %w[y yes].includes?(answer.strip.downcase)
    end
  end
end
