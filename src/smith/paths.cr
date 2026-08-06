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
end
