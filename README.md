# ⚒️ smith

**smith** is a fast, local-first LLM Agent Harness written in [Crystal](https://crystal-lang.org/).

It is inspired by and built according to the policy-free agent loop principles outlined in the [Neo Architecture](https://github.com/owainlewis/neo/blob/main/ARCHITECTURE.md).

---

## ✨ Features

- **🚀 Policy-Free Core Agent Loop (`Smith::Agent`)**: Complete decoupling of conversation transcript, LLM provider calls, tool execution, and UI surfaces.
- **⚡ Fiber-Based Parallel Tool Execution (`Smith::Tools`)**: Concurrent execution of parallel-safe tools (`read_file`, `grep`, `glob`) via Crystal Fibers (`spawn` & `Channel`).
- **🤖 Subagent Supervision (`Smith::Subagents`)**: The parent agent can delegate subtasks to autonomous child subagents running in isolated fibers in `work` (full capabilities) or `inspect` (read-only) mode.
- **📡 Provider-Neutral LLM Layer (`Smith::LLM`)**: Ships with **OpenRouter** and **Ollama** (local models) support with exponential backoff retry logic. Default models: `qwen/qwen3.8-max` (OpenRouter) / `gemma4:latest` (Ollama).
- **📂 Project Context & Skills Catalog**:
  - Automatically loads instructions from `SMITH.md` or `AGENTS.md`.
  - Discovers reusable skills in `.smith/skills/<name>/SKILL.md` and expands `$skill-name` or `/skill-name` references at runtime.
- **💾 Atomic Session Persistence (`Smith::Session`)**: Saves local conversation history and token metrics under `~/.smith/sessions/` with seamless resume capabilities.
- **⚡ Native Performance**: Compiles to a lightweight native binary with sub-20ms test suite execution.

---

## 🛠️ Prerequisites & Installation

### Prerequisites
- [mise](https://mise.jdx.dev/) or [Crystal](https://crystal-lang.org/) (>= 1.21.0) installed.

### Setup & Build

```bash
# 1. Install Crystal via mise (if using mise)
mise use crystal@latest

# 2. Build the binary
crystal build src/smith.cr -o bin/smith

# 3. Run the test suite
crystal spec
```

---

## 🚀 Usage

Set your OpenRouter API key before running `smith`:

```bash
export OPENROUTER_API_KEY="sk-or-v1-your-key-here"
```

### Interactive Chat Mode

Start an interactive session:

```bash
./bin/smith chat
```

### Headless Mode

Run a single prompt in headless mode and exit:

```bash
./bin/smith run "Inspect src/smith/agent.cr and summarize its responsibility"
```

### Session Persistence

List saved sessions:

```bash
./bin/smith list
```

Resume a previous session (or latest session if ID is omitted):

```bash
./bin/smith resume [session_id]
```

### Command Line Options

```text
Usage: smith [command] [options] [prompt]

Commands:
  chat                       Start an interactive chat session (default)
  run <prompt>               Run a single prompt in headless mode and exit
  resume [<session_id>]      Resume an existing session (or latest session)
  sessions, list             List all saved local chat sessions

Options:
  -m MODEL, --model=MODEL    Specify the LLM model (default: qwen/qwen3.8-max)
  -p PROVIDER, --provider=PROVIDER Specify the provider (default: openrouter)
  -v, --version              Print version information
  -h, --help                 Show help banner
```

---

## 📂 Project Architecture

```text
src/
├── smith.cr                 # CLI entrypoint
└── smith/
    ├── agent.cr             # Policy-free agent turn loop & event dispatcher
    ├── cli.cr               # CLI OptionParser, command router & event renderer
    ├── events.cr            # Typed event stream (AssistantText, ToolStart, ToolFinished, etc.)
    ├── atomic_file.cr       # Atomic write helper for safe persistence
    ├── project_ctx.cr       # SMITH.md & AGENTS.md discovery
    ├── skills.cr            # Skill catalog discovery & $skill / /skill expansion
    ├── session.cr           # Session persistence store (~/.smith/sessions/)
    ├── subagents.cr         # Child agent supervisor & report handling
    ├── llm/
    │   ├── types.cr         # Provider-neutral Request, Response, Message & ToolSpec
    │   ├── provider.cr      # Abstract Provider base class
    │   ├── retry.cr         # Exponential backoff retry handler
    │   └── openrouter.cr    # OpenRouter API client adapter
    └── tools/
        ├── tool.cr          # Abstract Tool base class & ParallelTool marker
        ├── registry.cr      # Tool registry & Fiber parallel execution scheduler
        ├── bash.cr          # Shell command execution tool
        ├── read_file.cr     # File reading tool
        ├── write_file.cr    # File writing tool
        ├── edit_file.cr     # Precise string replacement tool
        ├── grep.cr          # Regex search tool
        ├── glob.cr          # File pattern search tool
        └── agent_tool.cr    # Delegated subagent execution tool
```

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
