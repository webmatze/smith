require "spec"
require "../src/smith/llm"
require "../src/smith/tools"
require "../src/smith/events"
require "../src/smith/agent"

# `FileUtils.rm_rf` asks `Dir.exists?` before recursing, and that raises on a
# symlink loop — which `rm_rf` then swallows, abandoning the rest of the tree.
# Any spec that plants one would leak its whole temp directory, on every run.
# `File.symlink?` uses lstat, so it answers for the link itself and never
# follows it anywhere.
def remove_tree(path : String) : Nil
  if File.symlink?(path)
    File.delete(path)
    return
  end

  return unless File.exists?(path)

  if File.directory?(path)
    Dir.children(path).each { |child| remove_tree(File.join(path, child)) }
    Dir.delete(path)
  else
    File.delete(path)
  end
end
