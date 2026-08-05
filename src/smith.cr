require "./smith/cli"

module Smith
  VERSION = "0.1.0"
end

Smith::CLI.start(ARGV)
