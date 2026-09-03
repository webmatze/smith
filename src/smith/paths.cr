require "path"

module Smith
  # Root directory for all of smith's user-level state: global instructions,
  # the skills catalog, saved sessions and the global config file.
  #
  # Overridable via SMITH_HOME, which is what the specs use to stay clear of a
  # developer's real ~/.smith.
  def self.home_dir : String
    ENV.fetch("SMITH_HOME", File.join(Path.home, ".smith"))
  end

  # Marketplace state: the registry, the clone cache and the installed plugins.
  # Named here rather than in `Smith::Marketplace` because the two catalogs read
  # the installed tree at startup and must not have to require the whole
  # marketplace module — which requires them back.
  def self.plugins_dir : String
    File.join(home_dir, "plugins")
  end

  # `installed/<marketplace>/<plugin>/`. The two path segments *are* the
  # provenance, which is what lets discovery answer "where did this skill come
  # from" without opening a single JSON file.
  def self.installed_plugins_dir : String
    File.join(plugins_dir, "installed")
  end

  # Whether this directory is the root of a git checkout.
  #
  # `File.exists?` rather than `Dir.exists?`, and that is the whole point: in a
  # normal clone `.git` is a directory, but in a **worktree** and in a
  # **submodule** it is a regular file holding a `gitdir:` line. Asking for a
  # directory says "no" there, and a walk that stops at the git root would run
  # past the project and up to the filesystem root — collecting another
  # project's instructions and config on the way.
  def self.git_root?(dir : String) : Bool
    File.exists?(File.join(dir, ".git"))
  end

  # The git root at or above `start_dir`, or nil outside a checkout.
  #
  # The boundary two upward walks share — the one that looks for
  # `.smith/config.toml` and the one that collects SMITH.md / AGENTS.md — so
  # they cannot disagree about where the project ends.
  def self.git_root(start_dir : String = Dir.current) : String?
    curr = File.expand_path(start_dir)

    loop do
      return curr if git_root?(curr)
      parent = File.dirname(curr)
      return nil if parent == curr
      curr = parent
    end
  end
end
