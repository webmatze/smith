require "spec"
require "file_utils"
require "../../src/smith/mcp/server_config"

private def capture(&) : String
  warnings = IO::Memory.new
  yield warnings
  warnings.to_s
end

describe Smith::MCP::ServerConfig do
  describe ".parse" do
    it "reads the format every other MCP client writes" do
      specs = Smith::MCP::ServerConfig.parse(%({
        "mcpServers": {
          "filesystem": {
            "command": "npx",
            "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
            "env": {"FOO": "bar"}
          }
        }
      }), "mcp.json", IO::Memory.new)

      specs.size.should eq(1)
      spec = specs.first
      spec.name.should eq("filesystem")
      spec.command.should eq("npx")
      spec.args.should eq(["-y", "@modelcontextprotocol/server-filesystem", "/tmp"])
      spec.env.should eq({"FOO" => "bar"})
    end

    it "defaults args and env" do
      spec = Smith::MCP::ServerConfig.parse(%({"mcpServers": {"x": {"command": "run-me"}}}), "mcp.json", IO::Memory.new).first
      spec.args.should be_empty
      spec.env.should be_empty
      spec.command_line.should eq("run-me")
    end

    it "stringifies non-string env values, which real configs contain" do
      spec = Smith::MCP::ServerConfig.parse(%({"mcpServers": {"x": {"command": "c", "env": {"PORT": 8080, "DEBUG": true}}}}), "mcp.json", IO::Memory.new).first
      spec.env.should eq({"PORT" => "8080", "DEBUG" => "true"})
    end

    # A typo in mcp.json must never stop smith from starting.
    it "warns and yields nothing for malformed JSON" do
      specs = [] of Smith::MCP::ServerSpec
      warnings = capture { |io| specs = Smith::MCP::ServerConfig.parse("{not json", "mcp.json", io) }

      specs.should be_empty
      warnings.should contain("malformed MCP config")
    end

    it "skips an entry without a command" do
      specs = [] of Smith::MCP::ServerSpec
      warnings = capture { |io| specs = Smith::MCP::ServerConfig.parse(%({"mcpServers": {"broken": {"args": ["x"]}, "fine": {"command": "c"}}}), "mcp.json", io) }

      specs.map(&.name).should eq(["fine"])
      warnings.should contain("no \"command\"")
    end

    it "skips a transport stage 1 does not speak, saying which" do
      specs = [] of Smith::MCP::ServerSpec
      warnings = capture { |io| specs = Smith::MCP::ServerConfig.parse(%({"mcpServers": {"remote": {"type": "http", "url": "https://example.com"}}}), "mcp.json", io) }

      specs.should be_empty
      warnings.should contain("stdio only")
    end

    it "honours disabled" do
      specs = Smith::MCP::ServerConfig.parse(%({"mcpServers": {"off": {"command": "c", "disabled": true}}}), "mcp.json", IO::Memory.new)
      specs.should be_empty
    end

    it "warns when the file has no mcpServers object" do
      warnings = capture { |io| Smith::MCP::ServerConfig.parse(%({"other": {}}), "mcp.json", io) }
      warnings.should contain("no \"mcpServers\"")
    end
  end

  describe ".discover" do
    it "lets a project entry replace a global one of the same name" do
      home = File.tempname("smith-mcp-home")
      project = File.tempname("smith-mcp-project")

      begin
        FileUtils.mkdir_p(home)
        FileUtils.mkdir_p(File.join(project, ".smith"))
        # The walk stops at a git root, so the project needs to look like one.
        FileUtils.mkdir_p(File.join(project, ".git"))

        File.write(File.join(home, "mcp.json"), %({"mcpServers": {
          "shared": {"command": "global-one"},
          "only-global": {"command": "g"}
        }}))
        File.write(File.join(project, ".smith", "mcp.json"), %({"mcpServers": {
          "shared": {"command": "project-one"}
        }}))

        ENV["SMITH_HOME"] = home
        specs = Smith::MCP::ServerConfig.discover(project, IO::Memory.new)

        specs.map(&.name).sort.should eq(["only-global", "shared"])
        specs.find { |s| s.name == "shared" }.not_nil!.command.should eq("project-one")
      ensure
        ENV.delete("SMITH_HOME")
        FileUtils.rm_rf(home)
        FileUtils.rm_rf(project)
      end
    end

    it "finds the project file from a subdirectory" do
      project = File.tempname("smith-mcp-project")

      begin
        FileUtils.mkdir_p(File.join(project, ".smith"))
        FileUtils.mkdir_p(File.join(project, ".git"))
        nested = File.join(project, "src", "deep")
        FileUtils.mkdir_p(nested)
        File.write(File.join(project, ".smith", "mcp.json"), %({"mcpServers": {"x": {"command": "c"}}}))

        ENV["SMITH_HOME"] = File.join(project, "nowhere")
        Smith::MCP::ServerConfig.discover(nested, IO::Memory.new).map(&.name).should eq(["x"])
      ensure
        ENV.delete("SMITH_HOME")
        FileUtils.rm_rf(project)
      end
    end

    it "stops at a worktree root, so a neighbour's servers are not launched" do
      outer = File.tempname("smith-mcp-worktree")
      project = File.join(outer, "worktree")

      begin
        # An mcp.json names commands smith spawns at startup, and nothing gates
        # them the way TrustStore gates hooks. Walking past the project root
        # would start somebody else's processes.
        FileUtils.mkdir_p(File.join(outer, ".smith"))
        File.write(File.join(outer, ".smith", "mcp.json"), %({"mcpServers": {"outsider": {"command": "c"}}}))

        FileUtils.mkdir_p(project)
        File.write(File.join(project, ".git"), "gitdir: #{outer}/.git/worktrees/worktree\n")

        ENV["SMITH_HOME"] = File.join(outer, "nowhere")
        Smith::MCP::ServerConfig.discover(project, IO::Memory.new).should be_empty
      ensure
        ENV.delete("SMITH_HOME")
        FileUtils.rm_rf(outer)
      end
    end

    it "yields nothing when no config exists" do
      empty = File.tempname("smith-mcp-empty")

      begin
        FileUtils.mkdir_p(File.join(empty, ".git"))
        ENV["SMITH_HOME"] = File.join(empty, "home")
        Smith::MCP::ServerConfig.discover(empty, IO::Memory.new).should be_empty
      ensure
        ENV.delete("SMITH_HOME")
        FileUtils.rm_rf(empty)
      end
    end
  end
end
