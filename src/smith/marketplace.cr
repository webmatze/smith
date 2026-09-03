require "json"
require "file_utils"
require "./paths"
require "./atomic_file"
require "./skills"
require "./agents"

# Claude-Code-compatible plugin marketplaces.
#
# A marketplace is a git repository (or a plain directory) holding
# `.claude-plugin/marketplace.json`, which lists plugins. A plugin is a
# directory with `.claude-plugin/plugin.json` and component directories —
# smith reads the two components it has a home for, `skills/` and `agents/`,
# and refuses the rest out loud rather than dropping it silently.
#
# Nothing here runs at startup. Discovery (see `Skills::Catalog` and
# `Agents::Catalog`) reads the installed tree on disk; git, the network and
# every JSON file in this module are reached only by `smith plugin …`.
module Smith::Marketplace
  # Everything a subcommand can refuse for. Carries a finished sentence: the
  # CLI prints it behind "❌ Error: " and adds nothing.
  class Error < Exception
  end

  # ~/.smith/plugins — registry, clone cache and installed plugins.
  def self.root_dir : String
    Smith.plugins_dir
  end

  def self.registry_path : String
    File.join(root_dir, "marketplaces.json")
  end

  def self.cache_dir : String
    File.join(root_dir, "cache")
  end

  # `installed/<marketplace>/<plugin>/`. The two path segments are the
  # provenance, which is why discovery needs to read no JSON at all.
  def self.installed_dir : String
    Smith.installed_plugins_dir
  end

  # The sidecar beside an installed plugin: which marketplace it came from,
  # what its source said, the version that was resolved, what was ignored.
  META_FILE = "plugin.json.meta"

  # Components a plugin may carry that smith deliberately does not load. Named
  # in a warning and in the install summary, never dropped in silence.
  #
  # `hooks` above all: a hook is code execution outside the approval gate and
  # needs the TrustStore digest model before it may be loaded at all.
  IGNORED_COMPONENTS = {
    "hooks/hooks.json" => "hooks",
    "hooks"            => "hooks",
    ".mcp.json"        => "mcpServers",
    "commands"         => "commands",
    "themes"           => "themes",
    "monitors"         => "monitors",
  }

  # Keys in `plugin.json` that declare components smith does not load.
  IGNORED_MANIFEST_KEYS = %w[hooks mcpServers lspServers headersHelper]

  # ---------------------------------------------------------------------------
  # Names and paths
  # ---------------------------------------------------------------------------

  # A marketplace is untrusted third-party data, and both its own name and the
  # names of its plugins become directory names under ~/.smith. Everything that
  # reaches the filesystem passes through here first.
  module Safe
    # No `/`, no `..`, no leading `-` (which git and getopt would read as a
    # flag), no NUL, never absolute.
    NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

    # Branch, tag or refspec. Reaches a git command line, so the same leading-`-`
    # rule applies; `..`, `~`, `^`, `:` and whitespace are rejected outright.
    REF = /\A[A-Za-z0-9][A-Za-z0-9._\/-]*\z/

    SHA = /\A[0-9a-f]{7,40}\z/

    # owner/repo, the GitHub shorthand.
    REPO = /\A[A-Za-z0-9][A-Za-z0-9._-]*\/[A-Za-z0-9][A-Za-z0-9._-]*\z/

    # Deliberately narrow: no `ext::`, no `file://`, no `git://`, no `ssh://`
    # and no `git@host:path`. `ext::` alone is remote code execution, and
    # `--upload-pack=` smuggled through a URL is argument injection into the
    # clone. https only, and the character class keeps a shell-hostile URL out
    # even though nothing here goes through a shell.
    HTTPS_URL = /\Ahttps:\/\/[A-Za-z0-9][A-Za-z0-9._~:\/?#\[\]@!$&'()*+,;=%-]*\z/

    def self.name?(value : String?) : Bool
      !value.nil? && value.matches?(NAME) && value.size <= 128
    end

    def self.name!(value : String?, what : String) : String
      raise Error.new("#{what} is missing.") if value.nil? || value.empty?
      unless name?(value)
        raise Error.new("#{what} #{value.inspect} is not a usable name — letters, digits, '.', '_' and '-' only, and it may not start with '-'.")
      end
      value
    end

    def self.ref!(value : String?) : String?
      return nil if value.nil? || value.empty?
      if !value.matches?(REF) || value.includes?("..") || value.size > 200
        raise Error.new("ref #{value.inspect} is not a usable git ref.")
      end
      value
    end

    def self.sha!(value : String?) : String?
      return nil if value.nil? || value.empty?
      raise Error.new("sha #{value.inspect} is not a commit id.") unless value.matches?(SHA)
      value
    end

    def self.url!(value : String?) : String
      raise Error.new("a git source needs a url.") if value.nil? || value.empty?
      unless value.matches?(HTTPS_URL)
        raise Error.new("git url #{value.inspect} is refused — smith clones over https:// only. ssh (git@…), git://, file:// and ext:: URLs are not accepted, because ext:: is arbitrary code execution and the rest cannot be checked.")
      end
      value
    end
  end

  # Whether `path` is `root` itself or below it, both already resolved.
  def self.within?(root : String, path : String) : Bool
    path == root || path.starts_with?(root + File::SEPARATOR)
  end

  # Symlinks make a lexical check a lie, so the real path is compared wherever
  # one exists. `Dir.tempdir` on macOS is a symlink (/var → /private/var), so
  # resolving only one side would fail spuriously as well.
  def self.real_path(path : String) : String
    File.realpath(path)
  rescue File::Error
    File.expand_path(path)
  end

  # Resolve a marketplace-supplied relative path under `root`, refusing
  # anything that leaves it.
  #
  # This is the module's central security check: `source` comes from a JSON
  # file written by a stranger, and `"../../../.ssh"` would otherwise be copied
  # into ~/.smith and loaded as a skill.
  def self.resolve_within(root : String, relative : String, what : String = "source") : String
    raise Error.new("#{what} #{relative.inspect} contains a NUL byte.") if relative.includes?('\0')
    if relative.empty?
      raise Error.new("#{what} is empty.")
    end
    if Path.posix(relative).absolute? || Path.windows(relative).absolute?
      raise Error.new("#{what} #{relative.inspect} is absolute — a plugin source must be a path relative to the marketplace root.")
    end
    if relative.split(/[\/\\]/).includes?("..")
      raise Error.new("#{what} #{relative.inspect} leaves the marketplace root with '..', which is not allowed.")
    end

    # Resolved on both sides, and the candidate is built *from* the resolved
    # root: `Dir.tempdir` on macOS is /var → /private/var, so comparing a
    # /var/… candidate against a /private/var/… root would refuse every path in
    # a spec while letting nothing extra through in production.
    root_real = real_path(root)
    candidate = File.expand_path(File.join(root_real, relative))
    unless within?(root_real, candidate)
      raise Error.new("#{what} #{relative.inspect} resolves outside the marketplace root.")
    end

    # A path that exists may still be a symlink pointing out of the tree.
    if File.exists?(candidate) && !within?(root_real, real_path(candidate))
      raise Error.new("#{what} #{relative.inspect} is a symlink that leaves the marketplace root.")
    end

    candidate
  end

  # The mirror of the check above, for the writing side: every install target
  # has to land inside ~/.smith/plugins/installed/.
  def self.install_target(marketplace : String, plugin : String) : String
    Safe.name!(marketplace, "marketplace name")
    Safe.name!(plugin, "plugin name")

    base = installed_dir
    target = File.expand_path(File.join(base, marketplace, plugin))
    # Belt and braces: the names are validated above, so this can only fail if
    # the validator ever loosens.
    unless within?(File.expand_path(base), target)
      raise Error.new("refusing to install #{plugin.inspect}: the target path leaves #{base}.")
    end
    target
  end

  # ---------------------------------------------------------------------------
  # Sources
  # ---------------------------------------------------------------------------

  enum SourceKind
    Relative
    GitHub
    GitUrl
    GitSubdir
    Archive
    Npm
    Command
    Unknown
  end

  # Where one plugin's files come from, as the marketplace declared it.
  #
  # Parsed leniently on purpose: a marketplace holding one `npm` plugin must
  # still list, and `smith plugin install` must be the place that refuses it.
  # A strict union would have failed the whole `marketplace.json` instead.
  struct Source
    getter kind : SourceKind
    getter path : String?
    getter repo : String?
    getter url : String?
    getter ref : String?
    getter sha : String?
    getter raw : JSON::Any

    def initialize(
      @kind : SourceKind,
      @raw : JSON::Any,
      @path : String? = nil,
      @repo : String? = nil,
      @url : String? = nil,
      @ref : String? = nil,
      @sha : String? = nil,
    )
    end

    def self.parse(value : JSON::Any?) : Source
      return Source.new(SourceKind::Unknown, JSON::Any.new(nil)) if value.nil?

      if text = value.as_s?
        return Source.new(SourceKind::Relative, value, path: text)
      end

      object = value.as_h?
      return Source.new(SourceKind::Unknown, value) if object.nil?

      declared = object["source"]?.try(&.as_s?)
      ref = object["ref"]?.try(&.as_s?)
      sha = object["sha"]?.try(&.as_s?)

      case declared
      when "github"
        Source.new(SourceKind::GitHub, value, repo: object["repo"]?.try(&.as_s?), ref: ref, sha: sha)
      when "url", "git"
        Source.new(SourceKind::GitUrl, value, url: object["url"]?.try(&.as_s?), ref: ref, sha: sha)
      when "git-subdir"
        Source.new(SourceKind::GitSubdir, value, url: object["url"]?.try(&.as_s?), path: object["path"]?.try(&.as_s?), ref: ref, sha: sha)
      when "archive"
        Source.new(SourceKind::Archive, value, url: object["url"]?.try(&.as_s?))
      when "npm"
        Source.new(SourceKind::Npm, value)
      when "command"
        Source.new(SourceKind::Command, value)
      when Nil
        # A bare object without a `source` discriminator still says what it is.
        if repo = object["repo"]?.try(&.as_s?)
          Source.new(SourceKind::GitHub, value, repo: repo, ref: ref, sha: sha)
        elsif url = object["url"]?.try(&.as_s?)
          Source.new(SourceKind::GitUrl, value, url: url, ref: ref, sha: sha)
        else
          Source.new(SourceKind::Unknown, value)
        end
      else
        # `{"source": "./plugins/foo"}` — the long form of the string source.
        Source.new(SourceKind::Relative, value, path: declared)
      end
    end

    def supported? : Bool
      kind.relative? || kind.git_hub? || kind.git_url?
    end

    # nil when the source is one smith installs; a finished sentence otherwise.
    def refusal : String?
      case kind
      when .git_subdir?
        "'git-subdir' sources are Phase 2 — smith clones whole repositories today and has no partial checkout yet."
      when .archive?
        "'archive' sources are Phase 2 — an HTTPS zip needs redirect checking and sha256 verification before smith will unpack it."
      when .npm?
        "'npm' sources are not supported and will not be: installing one means running a package manager smith does not ship, manage or sandbox."
      when .command?
        "'command' sources are not supported and will not be: the plugin is produced by running an arbitrary command, which is code execution outside every gate smith has."
      when .unknown?
        "the source is not a form smith understands. Supported: a relative path, {\"source\":\"github\",\"repo\":\"owner/repo\"} or {\"source\":\"url\",\"url\":\"https://…\"}."
      else
        nil
      end
    end

    # One line for `marketplace list` and `plugin list`.
    def to_s(io : IO) : Nil
      case kind
      when .relative?
        io << (path || "(unnamed path)")
      when .git_hub?
        io << "github:" << (repo || "?")
        io << "@" << ref if ref
        io << " (" << sha.not_nil![0, 8] << ")" if sha
      when .git_url?
        io << (url || "?")
        io << "#" << ref if ref
      when .git_subdir?
        io << "git-subdir:" << (url || "?") << "//" << (path || "?")
      when .archive?
        io << "archive:" << (url || "?")
      when .npm?
        io << "npm"
      when .command?
        io << "command"
      else
        io << "unknown"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Manifests
  # ---------------------------------------------------------------------------

  struct PluginEntry
    getter name : String
    getter source : Source
    getter description : String?
    getter version : String?
    getter author : String?

    def initialize(@name : String, @source : Source, @description : String? = nil, @version : String? = nil, @author : String? = nil)
    end
  end

  # `.claude-plugin/marketplace.json`, parsed.
  class Manifest
    MANIFEST_PATH = File.join(".claude-plugin", "marketplace.json")

    getter name : String
    getter owner : String?
    getter description : String?
    getter version : String?
    # `metadata.pluginRoot`: the directory under which a bare source name
    # resolves. Relative to the marketplace root, like every other source path.
    getter plugin_root : String?
    # Old plugin name → new name, or nil where a plugin was withdrawn.
    getter renames : Hash(String, String?)
    getter plugins : Array(PluginEntry)
    getter warnings : Array(String)

    def initialize(
      @name : String,
      @owner : String?,
      @description : String?,
      @version : String?,
      @plugin_root : String?,
      @renames : Hash(String, String?),
      @plugins : Array(PluginEntry),
      @warnings : Array(String),
    )
    end

    def [](plugin_name : String) : PluginEntry?
      @plugins.find { |entry| entry.name == plugin_name }
    end

    # Follows `renames` so a marketplace can move a plugin without breaking the
    # name people already typed.
    def resolve(plugin_name : String) : PluginEntry
      if entry = self[plugin_name]
        return entry
      end

      if @renames.has_key?(plugin_name)
        replacement = @renames[plugin_name]
        raise Error.new("plugin #{plugin_name.inspect} was withdrawn from marketplace #{@name.inspect}.") if replacement.nil?
        if entry = self[replacement]
          return entry
        end
        raise Error.new("plugin #{plugin_name.inspect} was renamed to #{replacement.inspect}, which marketplace #{@name.inspect} does not list.")
      end

      known = @plugins.map(&.name).sort
      raise Error.new("marketplace #{@name.inspect} has no plugin #{plugin_name.inspect}.#{known.empty? ? "" : " It lists: #{known.join(", ")}."}")
    end

    def self.load(root : String) : Manifest
      path = File.join(root, MANIFEST_PATH)
      unless File.exists?(path)
        raise Error.new("#{root} is not a marketplace: no #{MANIFEST_PATH} in it.")
      end

      parse(File.read(path), path)
    rescue ex : IO::Error
      raise Error.new("could not read #{File.join(root, MANIFEST_PATH)}: #{ex.message}")
    end

    def self.parse(content : String, origin : String = "marketplace.json") : Manifest
      document = begin
        JSON.parse(content)
      rescue ex : JSON::ParseException
        raise Error.new("#{origin} is not valid JSON: #{ex.message}")
      end

      object = document.as_h?
      raise Error.new("#{origin} must be a JSON object.") if object.nil?

      warnings = Array(String).new

      name = object["name"]?.try(&.as_s?)
      raise Error.new("#{origin} has no \"name\".") if name.nil? || name.empty?
      Safe.name!(name, "marketplace name")

      owner = case owner_value = object["owner"]?
              when Nil then nil
              else          owner_value.as_s? || owner_value.as_h?.try { |h| h["name"]?.try(&.as_s?) }
              end
      warnings << "the marketplace declares no owner." if owner.nil?

      metadata = object["metadata"]?.try(&.as_h?)
      plugin_root = metadata.try { |m| m["pluginRoot"]?.try(&.as_s?) }

      renames = Hash(String, String?).new
      object["renames"]?.try(&.as_h?).try do |map|
        map.each { |from, to| renames[from] = to.as_s? }
      end

      entries = Array(PluginEntry).new
      list = object["plugins"]?.try(&.as_a?)
      raise Error.new("#{origin} has no \"plugins\" array.") if list.nil?

      list.each_with_index do |value, index|
        entry = value.as_h?
        if entry.nil?
          warnings << "plugin ##{index + 1} is not an object; it was skipped."
          next
        end

        plugin_name = entry["name"]?.try(&.as_s?)
        if plugin_name.nil? || plugin_name.empty?
          warnings << "plugin ##{index + 1} has no name; it was skipped."
          next
        end

        unless Safe.name?(plugin_name)
          warnings << "plugin #{plugin_name.inspect} has a name that cannot be a directory; it was skipped."
          next
        end

        # No source at all means "a directory named like the plugin", which is
        # what pluginRoot exists for.
        source = entry.has_key?("source") ? Source.parse(entry["source"]) : Source.parse(JSON::Any.new(plugin_name))

        entries << PluginEntry.new(
          name: plugin_name,
          source: source,
          description: entry["description"]?.try(&.as_s?),
          version: entry["version"]?.try(&.as_s?),
          author: entry["author"]?.try { |a| a.as_s? || a.as_h?.try { |h| h["name"]?.try(&.as_s?) } }
        )
      end

      Manifest.new(name, owner, object["description"]?.try(&.as_s?), object["version"]?.try(&.as_s?),
        plugin_root, renames, entries, warnings)
    end

    # Where a plugin entry's files live inside the marketplace checkout.
    # Raises rather than returning a path that leaves `root`.
    def source_dir(root : String, entry : PluginEntry) : String
      path = entry.source.path
      raise Error.new("plugin #{entry.name.inspect} has no source path.") if path.nil? || path.empty?

      # A bare name resolves under `metadata.pluginRoot`; anything written as a
      # path stays relative to the marketplace root.
      relative =
        if path.starts_with?("./") || path.starts_with?("../") || path.starts_with?("/") || plugin_root.nil?
          path
        else
          File.join(plugin_root.not_nil!, path)
        end

      Marketplace.resolve_within(root, relative, "plugin source")
    end
  end

  # `.claude-plugin/plugin.json`, parsed. Optional: a plugin directory without
  # one still installs, under the name the marketplace gave it.
  struct PluginManifest
    MANIFEST_PATH = File.join(".claude-plugin", "plugin.json")

    getter name : String?
    getter description : String?
    getter version : String?
    getter declared_components : Array(String)

    def initialize(@name : String?, @description : String?, @version : String?, @declared_components : Array(String))
    end

    def self.load(plugin_dir : String) : PluginManifest?
      path = File.join(plugin_dir, MANIFEST_PATH)
      return nil unless File.exists?(path)

      object = JSON.parse(File.read(path)).as_h?
      return nil if object.nil?

      PluginManifest.new(
        name: object["name"]?.try(&.as_s?),
        description: object["description"]?.try(&.as_s?),
        version: object["version"]?.try(&.as_s?),
        declared_components: IGNORED_MANIFEST_KEYS.select { |key| object.has_key?(key) }
      )
    rescue JSON::ParseException | IO::Error
      nil
    end
  end

  # ---------------------------------------------------------------------------
  # Git
  # ---------------------------------------------------------------------------

  # Every git invocation smith makes. A subprocess with a timeout and no way to
  # ask a question: a clone that stops on a credential prompt would otherwise
  # hang a headless command forever.
  module Git
    DEFAULT_TIMEOUT = 120

    record Result, status : Int32, output : String, error : String do
      def ok? : Bool
        status == 0
      end

      def message : String
        text = error.strip
        text = output.strip if text.empty?
        text.lines.last? || "git exited with #{status}"
      end
    end

    # `GIT_TERMINAL_PROMPT=0` and a closed stdin are the two halves of "cannot
    # block on a question"; the empty askpass variables stop an inherited GUI
    # prompter from taking over, and the empty credential.helper stops a
    # configured keychain helper from doing the same.
    ENVIRONMENT = {
      "GIT_TERMINAL_PROMPT" => "0",
      "GIT_ASKPASS"         => "",
      "SSH_ASKPASS"         => "",
      "GIT_PAGER"           => "cat",
    }

    PREFIX = ["-c", "credential.helper="]

    def self.available? : Bool
      run(["--version"], timeout: 10).ok?
    end

    def self.run(arguments : Array(String), chdir : String? = nil, timeout : Int32 = DEFAULT_TIMEOUT) : Result
      output = IO::Memory.new
      error = IO::Memory.new

      process = begin
        Process.new("git", PREFIX + arguments,
          chdir: chdir,
          input: Process::Redirect::Close,
          output: output,
          error: error,
          env: ENVIRONMENT)
      rescue ex : Exception
        return Result.new(127, "", "git could not be started (#{ex.message}). Is git on PATH?")
      end

      status = wait(process, timeout)
      return Result.new(124, output.to_s, "git #{arguments.first? || ""} timed out after #{timeout}s") if status.nil?

      Result.new(status.exit_code, output.to_s, error.to_s)
    end

    private def self.wait(process : Process, timeout : Int32) : Process::Status?
      channel = Channel(Process::Status).new(1)
      spawn { channel.send(process.wait) }

      select
      when status = channel.receive
        status
      when timeout(timeout.seconds)
        process.signal(Signal::KILL) rescue nil
        # Reap it, so a killed clone does not linger as a zombie.
        spawn { channel.receive }
        nil
      end
    end

    # Fetch `url` into `dest` at the requested ref or sha, and answer the commit
    # that ended up checked out.
    #
    # `init` + `fetch` rather than `clone --depth 1`: a clone has to guess the
    # default branch name, and `clone --depth` silently degrades to a full clone
    # for a local path — which would make the local fixture in the specs behave
    # differently from the real thing. Fetching `HEAD` asks the remote what its
    # default is instead.
    def self.materialize(url : String, dest : String, ref : String? = nil, sha : String? = nil, timeout : Int32 = DEFAULT_TIMEOUT) : String
      FileUtils.rm_rf(dest) if File.exists?(dest)
      FileUtils.mkdir_p(File.dirname(dest))

      check!(run(["init", "-q", dest], timeout: timeout), "initialise #{dest}")
      check!(run(["remote", "add", "origin", url], chdir: dest, timeout: timeout), "add the remote #{url}")

      fetch!(dest, ref, sha, timeout)
      head(dest, timeout)
    end

    # Re-fetch an existing checkout in place. The caller falls back to a fresh
    # materialize when this fails — the cache is disposable.
    def self.refresh(dest : String, ref : String? = nil, sha : String? = nil, timeout : Int32 = DEFAULT_TIMEOUT) : String
      raise Error.new("#{dest} is not a git checkout.") unless File.exists?(File.join(dest, ".git"))

      fetch!(dest, ref, sha, timeout)
      head(dest, timeout)
    end

    def self.head(dest : String, timeout : Int32 = DEFAULT_TIMEOUT) : String
      result = run(["rev-parse", "HEAD"], chdir: dest, timeout: timeout)
      check!(result, "read the checked-out commit")
      result.output.strip
    end

    private def self.fetch!(dest : String, ref : String?, sha : String?, timeout : Int32) : Nil
      target = sha || ref || "HEAD"

      # Shallow first; a server (or a transport) that refuses a shallow fetch of
      # this particular ref is answered with a full one rather than a failure.
      result = run(["fetch", "--depth", "1", "origin", target], chdir: dest, timeout: timeout)
      unless result.ok?
        result = run(["fetch", "origin"], chdir: dest, timeout: timeout)
        check!(result, "fetch #{target}")
      end

      # FETCH_HEAD is what the fetch above just wrote, which avoids naming a
      # branch smith would otherwise have to guess.
      checkout = run(["checkout", "-q", "--detach", "FETCH_HEAD"], chdir: dest, timeout: timeout)
      unless checkout.ok?
        # A full fallback fetch does not set FETCH_HEAD to the pinned sha.
        checkout = run(["checkout", "-q", "--detach", target], chdir: dest, timeout: timeout) if sha
        check!(checkout, "check out #{target}")
      end
    end

    private def self.check!(result : Result, what : String) : Nil
      return if result.ok?
      raise Error.new("could not #{what}: #{result.message}")
    end
  end

  # ---------------------------------------------------------------------------
  # Where a marketplace was added from
  # ---------------------------------------------------------------------------

  # The `<source>` argument of `smith plugin marketplace add`, resolved.
  #
  # Either a directory used where it lies (`dir`) or a git repository to clone
  # into the cache (`url`). Which one a local path is decided by what it holds:
  # a directory carrying `.claude-plugin/marketplace.json` is the marketplace, a
  # directory without one is a repository to clone (which is what a bare repo
  # is).
  struct Origin
    getter spec : String
    getter url : String?
    getter dir : String?
    getter ref : String?

    def initialize(@spec : String, @url : String? = nil, @dir : String? = nil, @ref : String? = nil)
    end

    def local? : Bool
      !@dir.nil?
    end

    def self.parse(spec : String) : Origin
      text = spec.strip
      raise Error.new("'smith plugin marketplace add' needs a source.") if text.empty?
      raise Error.new("the source contains a NUL byte.") if text.includes?('\0')

      if local_path?(text)
        path = File.expand_path(text.starts_with?("~") ? text.sub("~", Path.home.to_s) : text)
        raise Error.new("#{path} does not exist.") unless File.exists?(path)
        raise Error.new("#{path} is not a directory.") unless Dir.exists?(path)

        return Origin.new(text, dir: path) if File.exists?(File.join(path, Manifest::MANIFEST_PATH))
        # No manifest in the tree: treat it as a repository to clone. A bare
        # repository is exactly this case.
        return Origin.new(text, url: path)
      end

      if text.starts_with?("https://")
        url, _, fragment = text.partition("#")
        return Origin.new(text, url: Safe.url!(url), ref: Safe.ref!(fragment.empty? ? nil : fragment))
      end

      repo, _, at_ref = text.partition("@")
      if repo.matches?(Safe::REPO)
        return Origin.new(text, url: "https://github.com/#{repo}", ref: Safe.ref!(at_ref.empty? ? nil : at_ref))
      end

      raise Error.new(<<-MSG)
        #{text.inspect} is not a marketplace source smith accepts.
           Use one of: owner/repo[@ref], https://host/path/repo.git[#ref], or a local path starting with './', '../', '/' or '~/'.
           ssh (git@…), git://, file:// and ext:: sources are refused on purpose.
        MSG
    end

    private def self.local_path?(text : String) : Bool
      text.starts_with?("./") || text.starts_with?("../") ||
        text.starts_with?("/") || text.starts_with?("~/") ||
        text == "." || text == ".."
    end
  end

  # ---------------------------------------------------------------------------
  # Registry
  # ---------------------------------------------------------------------------

  # A class rather than a struct: `marketplace update` writes the new commit
  # back into the entry it read out of the registry, and a struct would have
  # handed it a copy to update.
  class RegistryEntry
    include JSON::Serializable

    property name : String
    # The source exactly as it was typed, so `marketplace list` can show it.
    property source : String
    property url : String?
    property dir : String?
    property ref : String?
    property commit : String?
    property added_at : String
    property updated_at : String

    def initialize(@name, @source, @url, @dir, @ref, @commit, @added_at, @updated_at)
    end

    def local? : Bool
      !@dir.nil?
    end

    # Where the marketplace tree lives: a local directory stays where it is, a
    # cloned one lives in the cache under its own name.
    def root : String
      @dir || File.join(Marketplace.cache_dir, @name)
    end
  end

  class Registry
    include JSON::Serializable

    property version : Int32 = 1
    # Keyed by name, which is what makes re-adding a marketplace replace the
    # previous entry rather than duplicate it — the Claude Code behaviour.
    property marketplaces : Hash(String, RegistryEntry) = Hash(String, RegistryEntry).new

    def initialize
    end

    def self.load : Registry
      path = Marketplace.registry_path
      return Registry.new unless File.exists?(path)

      registry = Registry.from_json(File.read(path))
      # The names in this file become directory names under ~/.smith — for
      # `marketplace remove`, a directory it deletes. smith only ever writes
      # validated names here, but the file is editable, so it is validated on
      # the way in too rather than trusted for having been ours once.
      registry.marketplaces.reject! { |name, entry| !Safe.name?(name) || name != entry.name }
      registry
    rescue JSON::ParseException | IO::Error
      # A registry smith cannot read must not brick `smith plugin list`; the
      # next write replaces it.
      Registry.new
    end

    def save : Nil
      AtomicFile.write(Marketplace.registry_path, to_pretty_json)
    end

    def [](name : String) : RegistryEntry
      @marketplaces[name]? || raise Error.new("no marketplace #{name.inspect} is registered.#{names.empty? ? " Add one with 'smith plugin marketplace add <source>'." : " Registered: #{names.join(", ")}."}")
    end

    def []?(name : String) : RegistryEntry?
      @marketplaces[name]?
    end

    def names : Array(String)
      @marketplaces.keys.sort
    end

    def empty? : Bool
      @marketplaces.empty?
    end
  end

  # ---------------------------------------------------------------------------
  # Installed plugins
  # ---------------------------------------------------------------------------

  struct InstallMeta
    include JSON::Serializable

    property plugin : String
    property marketplace : String
    # Both forms on purpose: one line a human can read, and the entry exactly
    # as the marketplace wrote it, so a later phase can tell what it asked for.
    property source : String
    property source_json : String = "null"
    property version : String
    property description : String?
    property installed_at : String
    property ignored : Array(String) = Array(String).new

    def initialize(@plugin, @marketplace, @source, @source_json, @version, @description, @installed_at, @ignored)
    end

    def self.load(dir : String) : InstallMeta?
      path = File.join(dir, META_FILE)
      return nil unless File.exists?(path)
      InstallMeta.from_json(File.read(path))
    rescue JSON::ParseException | IO::Error
      nil
    end
  end

  record Installed, marketplace : String, plugin : String, dir : String, meta : InstallMeta?

  # Every installed plugin on disk, marketplace first, then plugin. Reads only
  # the two-level directory tree — the same walk discovery does.
  def self.installed : Array(Installed)
    found = Array(Installed).new
    base = installed_dir
    return found unless Dir.exists?(base)

    Dir.children(base).sort.each do |marketplace|
      marketplace_dir = File.join(base, marketplace)
      next unless Dir.exists?(marketplace_dir)

      Dir.children(marketplace_dir).sort.each do |plugin|
        plugin_dir = File.join(marketplace_dir, plugin)
        next unless Dir.exists?(plugin_dir)

        found << Installed.new(marketplace, plugin, plugin_dir, InstallMeta.load(plugin_dir))
      end
    end

    found
  end

  # Copy a plugin tree, refusing to follow symlinks.
  #
  # `FileUtils.cp_r` follows them, and a plugin is untrusted: a `skills` entry
  # that is a symlink to `/` would copy the filesystem into ~/.smith, and one
  # pointing at `~/.ssh` would copy secrets into a directory whose contents are
  # read into a prompt.
  def self.copy_tree(from : String, to : String, skipped : Array(String) = Array(String).new, relative : String = "") : Nil
    FileUtils.mkdir_p(to, mode: 0o700)

    Dir.children(from).sort.each do |child|
      # The clone's own object store is not part of the plugin.
      next if child == ".git"

      source = File.join(from, child)
      target = File.join(to, child)
      here = relative.empty? ? child : File.join(relative, child)

      info = File.info(source, follow_symlinks: false)
      if info.type.symlink?
        skipped << here
        next
      end

      if info.type.directory?
        copy_tree(source, target, skipped, here)
      elsif info.type.file?
        File.copy(source, target)
      else
        skipped << here
      end
    end
  end

  # Which components of a plugin directory smith is not loading.
  def self.ignored_components(plugin_dir : String) : Array(String)
    found = Array(String).new

    IGNORED_COMPONENTS.each do |path, label|
      found << label if File.exists?(File.join(plugin_dir, path))
    end

    if manifest = PluginManifest.load(plugin_dir)
      found.concat(manifest.declared_components)
    end

    found.uniq.sort
  end

  # ---------------------------------------------------------------------------
  # Subcommands
  # ---------------------------------------------------------------------------

  # Everything `smith plugin …` does. Lives here rather than in the CLI: the
  # CLI's job is the verb and the exit code, and every failure below arrives as
  # a `Marketplace::Error` carrying a finished sentence.
  #
  # Headless throughout — nothing here asks a question.
  class Commands
    USAGE = <<-TEXT
      Usage:
         smith plugin marketplace add <source>     owner/repo[@ref], https://…[#ref] or ./path
         smith plugin marketplace list
         smith plugin marketplace remove <name>    also removes the plugins installed from it
         smith plugin marketplace update [name]    all of them when no name is given
         smith plugin install <plugin>@<marketplace>
         smith plugin uninstall <plugin>[@<marketplace>]
         smith plugin list
         smith plugin update [plugin]
      TEXT

    def initialize(@out : IO = STDOUT, @err : IO = STDERR)
      @registry = Registry.load
    end

    def dispatch(arguments : Array(String)) : Nil
      case arguments.first?
      when "marketplace", "marketplaces"
        marketplace(arguments[1]?, arguments[2]?)
      when "install"
        install(arguments[1]?)
      when "uninstall", "remove", "rm"
        uninstall(arguments[1]?)
      when nil, "list", "ls"
        list
      when "update"
        update(arguments[1]?)
      else
        raise Error.new("unknown 'smith plugin' subcommand #{arguments.first.inspect}.\n#{USAGE}")
      end
    end

    private def marketplace(subcommand : String?, argument : String?) : Nil
      case subcommand
      when "add"
        marketplace_add(argument)
      when nil, "list", "ls"
        marketplace_list
      when "remove", "rm"
        marketplace_remove(argument)
      when "update"
        marketplace_update(argument)
      else
        raise Error.new("unknown 'smith plugin marketplace' subcommand #{subcommand.inspect}.\n#{USAGE}")
      end
    end

    # -- marketplaces ---------------------------------------------------------

    private def marketplace_add(spec : String?) : Nil
      raise Error.new("'smith plugin marketplace add' needs a source.\n#{USAGE}") if spec.nil? || spec.strip.empty?

      origin = Origin.parse(spec)
      now = Time.utc.to_rfc3339

      if directory = origin.dir
        manifest = Manifest.load(directory)
        entry = RegistryEntry.new(manifest.name, origin.spec, nil, directory, nil, local_commit(directory), now, now)
      else
        # The cache directory is named after the marketplace, and the name lives
        # inside the checkout — so it lands in a staging directory first and is
        # renamed once the manifest has been read.
        staging = File.join(cache_dir, ".staging-#{Random::Secure.hex(6)}")
        begin
          commit = Git.materialize(origin.url.not_nil!, staging, ref: origin.ref)
          manifest = Manifest.load(staging)
          destination = File.join(cache_dir, manifest.name)
          FileUtils.rm_rf(destination) if File.exists?(destination)
          File.rename(staging, destination)
        ensure
          FileUtils.rm_rf(staging) if File.exists?(staging)
        end
        entry = RegistryEntry.new(manifest.name, origin.spec, origin.url, nil, origin.ref, commit, now, now)
      end

      replaced = @registry[manifest.name]?
      # Re-adding the same name from a local directory retires the clone the
      # previous entry left in the cache; nothing would ever look at it again.
      FileUtils.rm_rf(File.join(cache_dir, manifest.name)) if replaced && !replaced.local? && entry.local?

      @registry.marketplaces[manifest.name] = entry
      @registry.save

      @out.puts "#{replaced ? "🔁 Replaced" : "✅ Added"} marketplace '#{manifest.name}' — #{count(manifest.plugins.size, "plugin")}"
      @out.puts "   source:  #{entry.source}"
      @out.puts "   root:    #{entry.root}"
      @out.puts "   commit:  #{entry.commit || "(not a git checkout)"}"
      @out.puts "   plugins: #{manifest.plugins.map(&.name).sort.join(", ")}" unless manifest.plugins.empty?
      report_manifest(manifest)
      @out.puts "Install one with: smith plugin install <plugin>@#{manifest.name}"
    end

    private def marketplace_list : Nil
      if @registry.empty?
        @out.puts "No marketplaces registered."
        @out.puts "   Add one with: smith plugin marketplace add owner/repo"
        return
      end

      @out.puts "🏪 Marketplaces (#{@registry.marketplaces.size}):"
      @out.puts "-" * 80
      @out.printf("%-20s %-8s %-10s %s\n", "NAME", "PLUGINS", "COMMIT", "SOURCE")
      @out.puts "-" * 80

      @registry.names.each do |name|
        entry = @registry[name]
        plugins =
          begin
            Manifest.load(entry.root).plugins.size.to_s
          rescue Error
            "?"
          end

        @out.printf("%-20s %-8s %-10s %s\n", name, plugins, entry.commit.try(&.[0, 8]) || "local", entry.source)
      end

      @out.puts "-" * 80
      @out.puts "Refresh them with: smith plugin marketplace update"
    end

    private def marketplace_remove(name : String?) : Nil
      raise Error.new("'smith plugin marketplace remove' needs a marketplace name.\n#{USAGE}") if name.nil?

      entry = @registry[name]
      removed = Marketplace.installed.select { |plugin| plugin.marketplace == name }

      removed.each { |plugin| FileUtils.rm_rf(plugin.dir) }
      installed_root = File.join(Marketplace.installed_dir, name)
      FileUtils.rm_rf(installed_root) if Dir.exists?(installed_root)
      FileUtils.rm_rf(File.join(cache_dir, name)) unless entry.local?

      @registry.marketplaces.delete(name)
      @registry.save

      @out.puts "🗑️  Removed marketplace '#{name}'."
      if removed.empty?
        @out.puts "   No plugins were installed from it."
      else
        @out.puts "   Also uninstalled #{count(removed.size, "plugin")}: #{removed.map(&.plugin).join(", ")}"
      end
    end

    private def marketplace_update(name : String?) : Nil
      names = name ? [@registry[name].name] : @registry.names
      if names.empty?
        @out.puts "No marketplaces registered."
        return
      end

      names.each do |current|
        entry = @registry[current]

        if entry.local?
          manifest = Manifest.load(entry.root)
          entry.commit = local_commit(entry.root)
          entry.updated_at = Time.utc.to_rfc3339
          @out.puts "📁 #{current}: local directory #{entry.root} — #{count(manifest.plugins.size, "plugin")}"
          next
        end

        before = entry.commit
        after =
          begin
            Git.refresh(entry.root, ref: entry.ref)
          rescue Error
            # The cache is disposable; a half-broken checkout is re-made rather
            # than repaired.
            Git.materialize(entry.url.not_nil!, entry.root, ref: entry.ref)
          end

        entry.commit = after
        entry.updated_at = Time.utc.to_rfc3339

        if before == after
          @out.puts "✅ #{current}: up to date at #{after[0, 8]}"
        else
          @out.puts "⬆️  #{current}: #{before.try(&.[0, 8]) || "(new)"} → #{after[0, 8]}"
        end
      end

      @registry.save
      @out.puts "Update the plugins installed from them with: smith plugin update"
    end

    # -- plugins --------------------------------------------------------------

    private def install(reference : String?) : Nil
      raise Error.new("'smith plugin install' needs <plugin>@<marketplace>.\n#{USAGE}") if reference.nil? || reference.empty?

      plugin_name, _, marketplace_name = reference.partition("@")
      if marketplace_name.empty?
        raise Error.new("'smith plugin install' needs <plugin>@<marketplace> — for example '#{plugin_name}@#{@registry.names.first? || "my-plugins"}'.#{@registry.empty? ? "" : " Registered marketplaces: #{@registry.names.join(", ")}."}")
      end

      registry_entry = @registry[marketplace_name]
      manifest = Manifest.load(registry_entry.root)
      entry = manifest.resolve(plugin_name)

      if reason = entry.source.refusal
        raise Error.new("cannot install '#{entry.name}' from '#{manifest.name}': #{reason}")
      end

      staging = nil
      begin
        source_dir, source_commit = materialize_plugin(manifest, registry_entry, entry)
        staging = source_commit.nil? ? nil : source_dir

        plugin_manifest = PluginManifest.load(source_dir)
        version = plugin_manifest.try(&.version) || entry.version || source_commit || registry_entry.commit || "unknown"

        finish_install(manifest.name, entry, source_dir, version,
          plugin_manifest.try(&.description) || entry.description)
      ensure
        FileUtils.rm_rf(staging) if staging && Dir.exists?(staging)
      end
    end

    # Answers where the plugin's files are and, for a git source, the commit
    # they came from. The second element is nil for a path inside the
    # marketplace checkout, which is also the signal that there is nothing to
    # clean up afterwards.
    private def materialize_plugin(manifest : Manifest, registry_entry : RegistryEntry, entry : PluginEntry) : {String, String?}
      source = entry.source

      case source.kind
      when .relative?
        directory = manifest.source_dir(registry_entry.root, entry)
        unless Dir.exists?(directory)
          raise Error.new("plugin '#{entry.name}' points at #{source.path}, which is not a directory in marketplace '#{manifest.name}'.")
        end
        {directory, nil}
      when .git_hub?
        repo = source.repo
        unless repo && repo.matches?(Safe::REPO)
          raise Error.new("plugin '#{entry.name}' declares a github source with an unusable repo #{repo.inspect} — expected 'owner/repo'.")
        end
        clone_plugin("https://github.com/#{repo}", source)
      when .git_url?
        clone_plugin(Safe.url!(source.url), source)
      else
        raise Error.new("plugin '#{entry.name}': #{source.refusal || "unsupported source."}")
      end
    end

    private def clone_plugin(url : String, source : Source) : {String, String?}
      target = File.join(cache_dir, ".plugin-#{Random::Secure.hex(6)}")

      begin
        commit = Git.materialize(url, target, ref: Safe.ref!(source.ref), sha: Safe.sha!(source.sha))
      rescue ex
        # The caller only cleans up what it was handed back, so a fetch that
        # dies halfway would otherwise leave its half-clone in the cache.
        FileUtils.rm_rf(target) if File.exists?(target)
        raise ex
      end

      {target, commit}
    end

    private def finish_install(marketplace_name : String, entry : PluginEntry, source_dir : String, version : String, description : String?) : Nil
      target = Marketplace.install_target(marketplace_name, entry.name)
      ignored = Marketplace.ignored_components(source_dir)

      elsewhere = Marketplace.installed.select { |other| other.plugin == entry.name && other.marketplace != marketplace_name }

      FileUtils.rm_rf(target) if Dir.exists?(target)
      skipped = Array(String).new
      Marketplace.copy_tree(source_dir, target, skipped)

      meta = InstallMeta.new(entry.name, marketplace_name, entry.source.to_s, entry.source.raw.to_json,
        version, description, Time.utc.to_rfc3339, ignored)
      AtomicFile.write(File.join(target, META_FILE), meta.to_pretty_json)

      skills, agents = components(marketplace_name, entry.name, target)

      @out.puts "✅ Installed #{entry.name}@#{marketplace_name} #{version}"
      @out.puts "   path:    #{target}"
      @out.puts "   source:  #{entry.source}"
      @out.puts "   skills:  #{skills.empty? ? "(none)" : skills.join(", ")}"
      @out.puts "   agents:  #{agents.empty? ? "(none)" : agents.join(", ")}"

      unless ignored.empty?
        @out.puts "⚠️  Not loaded from this plugin: #{ignored.join(", ")}."
        @out.puts "   smith reads skills/ and agents/ only. Hooks are code execution outside the approval gate and stay out until they can be digest-pinned; MCP servers, LSP servers, commands, themes and monitors are later phases."
      end

      unless skipped.empty?
        @out.puts "⚠️  Skipped while copying (symlinks and special files are never followed): #{skipped.join(", ")}."
      end

      unless elsewhere.empty?
        @out.puts "⚠️  '#{entry.name}' is also installed from #{elsewhere.map(&.marketplace).join(", ")}; both claim the '#{entry.name}:' prefix, and the last one read wins. 'smith skills list' shows which."
      end

      if skills.empty? && agents.empty?
        @out.puts "   Nothing smith can load was found — the plugin holds no skills/ and no agents/."
      end
    end

    private def uninstall(reference : String?) : Nil
      raise Error.new("'smith plugin uninstall' needs a plugin name.\n#{USAGE}") if reference.nil? || reference.empty?

      wanted, _, marketplace_name = reference.partition("@")
      matches = Marketplace.installed.select do |plugin|
        plugin.plugin == wanted && (marketplace_name.empty? || plugin.marketplace == marketplace_name)
      end

      case matches.size
      when 0
        known = Marketplace.installed.map { |plugin| "#{plugin.plugin}@#{plugin.marketplace}" }
        raise Error.new("no plugin #{reference.inspect} is installed.#{known.empty? ? "" : " Installed: #{known.join(", ")}."}")
      when 1
        plugin = matches.first
        FileUtils.rm_rf(plugin.dir)
        prune_marketplace_dir(plugin.marketplace)
        @out.puts "🗑️  Uninstalled #{plugin.plugin}@#{plugin.marketplace}."
      else
        raise Error.new("#{wanted.inspect} is installed from more than one marketplace: #{matches.map(&.marketplace).join(", ")}. Name one, as '#{wanted}@#{matches.first.marketplace}'.")
      end
    end

    private def list : Nil
      plugins = Marketplace.installed
      if plugins.empty?
        @out.puts "No plugins installed."
        @out.puts "   Add a marketplace, then: smith plugin install <plugin>@<marketplace>"
        return
      end

      @out.puts "🧩 Installed plugins (#{plugins.size}):"
      @out.puts "-" * 80
      @out.printf("%-24s %-16s %-14s %s\n", "PLUGIN", "MARKETPLACE", "VERSION", "COMPONENTS")
      @out.puts "-" * 80

      plugins.each do |plugin|
        skills, agents = components(plugin.marketplace, plugin.plugin, plugin.dir)
        parts = Array(String).new
        parts << count(skills.size, "skill") unless skills.empty?
        parts << count(agents.size, "agent") unless agents.empty?
        ignored = plugin.meta.try(&.ignored) || Array(String).new
        parts << "ignored: #{ignored.join("/")}" unless ignored.empty?

        @out.printf("%-24s %-16s %-14s %s\n", plugin.plugin, plugin.marketplace,
          plugin.meta.try(&.version) || "?", parts.empty? ? "(nothing loadable)" : parts.join(", "))
      end

      @out.puts "-" * 80
      @out.puts "Skills and agents from a plugin are invoked as <plugin>:<name>; see 'smith skills list'."
    end

    private def update(name : String?) : Nil
      plugins = Marketplace.installed
      if wanted = name
        bare = wanted.partition("@")[0]
        plugins = plugins.select { |plugin| plugin.plugin == bare }
      end
      if plugins.empty?
        raise Error.new("no plugin #{name.inspect} is installed.") if name
        @out.puts "No plugins installed."
        return
      end

      plugins.each do |installed|
        registry_entry = @registry[installed.marketplace]?
        if registry_entry.nil?
          @out.puts "⚠️  #{installed.plugin}@#{installed.marketplace}: the marketplace is no longer registered; skipped."
          next
        end

        begin
          manifest = Manifest.load(registry_entry.root)
          entry = manifest.resolve(installed.plugin)
          if reason = entry.source.refusal
            @out.puts "⚠️  #{installed.plugin}@#{installed.marketplace}: #{reason}"
            next
          end

          staging = nil
          begin
            source_dir, source_commit = materialize_plugin(manifest, registry_entry, entry)
            staging = source_commit.nil? ? nil : source_dir

            plugin_manifest = PluginManifest.load(source_dir)
            version = plugin_manifest.try(&.version) || entry.version || source_commit || registry_entry.commit || "unknown"

            if installed.meta.try(&.version) == version
              @out.puts "✅ #{installed.plugin}@#{installed.marketplace}: up to date at #{version}"
              next
            end

            @out.puts "⬆️  #{installed.plugin}@#{installed.marketplace}: #{installed.meta.try(&.version) || "?"} → #{version}"
            finish_install(manifest.name, entry, source_dir, version,
              plugin_manifest.try(&.description) || entry.description)
          ensure
            FileUtils.rm_rf(staging) if staging && Dir.exists?(staging)
          end
        rescue ex : Error
          # One broken marketplace must not stop the others from updating.
          @out.puts "⚠️  #{installed.plugin}@#{installed.marketplace}: #{ex.message}"
        end
      end
    end

    # -- helpers --------------------------------------------------------------

    # Exactly what discovery will see, built with the catalogs themselves so the
    # summary cannot drift from what actually loads.
    private def components(marketplace : String, plugin : String, dir : String) : {Array(String), Array(String)}
      skills = Skills::Catalog.new
      skills.load_plugin_dir(marketplace, plugin, dir)

      agents = Agents::Catalog.new
      agents.load_plugin_dir(marketplace, plugin, dir)

      {skills.skills.keys.sort, agents.agents.keys.sort}
    end

    # An empty `installed/<marketplace>/` left behind after the last uninstall
    # would keep showing up as a provenance directory.
    private def prune_marketplace_dir(name : String) : Nil
      dir = File.join(Marketplace.installed_dir, name)
      FileUtils.rm_rf(dir) if Dir.exists?(dir) && Dir.children(dir).empty?
    end

    private def report_manifest(manifest : Manifest) : Nil
      manifest.warnings.each { |warning| @err.puts "⚠️  #{manifest.name}: #{warning}" }

      refused = manifest.plugins.select { |entry| entry.source.refusal }
      return if refused.empty?

      @out.puts "⚠️  #{count(refused.size, "plugin")} in this marketplace use a source smith will not install:"
      refused.each { |entry| @out.puts "   #{entry.name} (#{entry.source}) — #{entry.source.refusal}" }
    end

    # A marketplace added from a local directory may still be a git checkout,
    # and knowing which commit it is on is worth the one cheap call — but only
    # here, never on the startup path.
    private def local_commit(directory : String) : String?
      return nil unless File.exists?(File.join(directory, ".git"))

      result = Git.run(["rev-parse", "HEAD"], chdir: directory, timeout: 15)
      result.ok? ? result.output.strip : nil
    end

    private def cache_dir : String
      dir = Marketplace.cache_dir
      FileUtils.mkdir_p(dir, mode: 0o700) unless Dir.exists?(dir)
      dir
    end

    private def count(number : Int32, noun : String) : String
      "#{number} #{noun}#{number == 1 ? "" : "s"}"
    end
  end
end
