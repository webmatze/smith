# ⚒️ smith

[![CI](https://github.com/webmatze/smith/actions/workflows/ci.yml/badge.svg)](https://github.com/webmatze/smith/actions/workflows/ci.yml)

**smith** is a fast, local-first LLM Agent Harness written in [Crystal](https://crystal-lang.org/).

It is inspired by and built according to the policy-free agent loop principles outlined in the [Neo Architecture](https://github.com/owainlewis/neo/blob/main/ARCHITECTURE.md).

---

## ✨ Features

- **🚀 Policy-Free Core Agent Loop (`Smith::Agent`)**: Complete decoupling of conversation transcript, LLM provider calls, tool execution, and UI surfaces.
- **⚡ Fiber-Based Parallel Tool Execution (`Smith::Tools`)**: Concurrent execution of parallel-safe tools (`read_file`, `grep`, `glob`) via Crystal Fibers (`spawn` & `Channel`).
- **🤖 Subagent Supervision (`Smith::Subagents`)**: The parent agent can delegate subtasks to autonomous child subagents running in isolated fibers in `work` (full capabilities) or `inspect` (read-only) mode.
- **📡 Provider-Neutral LLM Layer (`Smith::LLM`)**: Ships with **OpenRouter**, **Ollama** (local models), **Anthropic** (Messages API), and **OpenAI** (Chat Completions) support with exponential backoff retry logic. Default models: `qwen/qwen3.8-max` (OpenRouter) / `gemma4:latest` (Ollama) / `claude-sonnet-5` (Anthropic) / `gpt-5.6-luna` (OpenAI).
- **📂 Project Context & Skills Catalog**:
  - Automatically loads instructions from `SMITH.md` or `AGENTS.md`, walking up from the current directory to the Git root, plus global instructions from `~/.smith/`.
  - Discovers reusable skills in `.smith/skills/<name>/SKILL.md` (project-local), `~/.smith/skills/` (global), as well as `.gemini/skills/` and `.agents/skills/`, and expands `$skill-name` or `/skill-name` references at runtime. The home directory can be overridden via the `SMITH_HOME` environment variable.
- **💾 Atomic Session Persistence (`Smith::Session`)**: Saves local conversation history and token metrics under `~/.smith/sessions/` with seamless resume capabilities.
- **⚡ Native Performance**: Compiles to a lightweight native binary; the test suite runs in well under a second.

---

## 🛠️ Prerequisites & Installation

### Prerequisites
- [mise](https://mise.jdx.dev/) or [Crystal](https://crystal-lang.org/) (>= 1.21.0) installed.

### Setup & Build

```bash
# 1. Install Crystal via mise (if using mise)
mise use crystal@latest

# 2. Install dependencies
shards install

# 3. Build the binary
mkdir -p bin
crystal build src/smith.cr -o bin/smith

# 4. Run the test suite
crystal spec
```

Alternatively, use the bundled `Makefile` (wraps `mise exec -- crystal ...` and signs the binary on macOS):

| Target | Description |
|---|---|
| `make build` | Compile `bin/smith` (debug build) |
| `make release` | Compile optimized `bin/smith` |
| `make test` | Run the test suite (`crystal spec`) |
| `make install` | Build release & install to `~/.local/bin/smith` |
| `make clean` | Remove `bin/` |

---

## 🚀 Usage

Set the API key for your chosen provider before running `smith`:

```bash
# OpenRouter (default provider)
export OPENROUTER_API_KEY="sk-or-v1-your-key-here"

# Anthropic
export ANTHROPIC_API_KEY="your-key-here"

# OpenAI
export OPENAI_API_KEY="your-key-here"

# Ollama needs no API key (optional: point to a non-default host)
export OLLAMA_HOST="http://localhost:11434"
```

### Configuration

Persistent defaults live in a TOML file, so provider and model no longer have to be passed as flags every time. Two locations are read:

| Location | Scope |
|---|---|
| `~/.smith/config.toml` | Global (override the directory via `SMITH_HOME`) |
| `.smith/config.toml` | Project — searched upward from the working directory to the Git root; the nearest one wins |

Values resolve in this order, highest priority first:

```text
CLI flag  >  environment variable  >  project config  >  global config  >  built-in default
```

A full example with every supported key:

```toml
[defaults]
provider = "openrouter"          # openrouter | ollama | anthropic | openai

[providers.openrouter]
model = "qwen/qwen3.8-max"

[providers.ollama]
model = "gemma4:latest"
host  = "http://localhost:11434"

[providers.anthropic]
model = "claude-sonnet-5"

[providers.openai]
model = "gpt-5.6-luna"

[http]
connect_timeout = 10             # seconds
read_timeout    = 120

[approval]
mode      = "prompt"             # prompt | auto
allowlist = ["ls", "git status"]

[context]
max_tokens = 120000
```

Relevant environment variables: `SMITH_PROVIDER`, `SMITH_MODEL`, `OLLAMA_HOST`, `SMITH_HOME`.

**API keys are never read from the config file.** They stay in environment variables only, so a plaintext config never becomes a place secrets get committed from.

`[http]` applies to all four providers. An elapsed `read_timeout` is **not** retried, so it is genuinely the longest smith will wait on a single call — connection errors and 429/5xx responses still go through the exponential-backoff retry handler.

The `[approval]` and `[context]` sections are parsed and exposed today but not yet acted upon — they are wired up by the approval-mode and context-compaction features.

Every key is optional; unknown keys are ignored, and a malformed file produces a warning on stderr rather than a crash.

### Interactive Chat Mode

Start an interactive session:

```bash
./bin/smith chat
```

Pressing **Ctrl+C** at any point — including mid-response — saves the session and exits with code 130, printing the `smith resume` command to pick it back up. Nothing in flight is lost.

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
  -m MODEL, --model=MODEL    Specify the LLM model (default: provider's default model)
  -p PROVIDER, --provider=PROVIDER Specify the provider: openrouter, ollama, anthropic, openai (default: openrouter)
  -v, --version              Print version information
  -h, --help                 Show help banner
```

You can also pass a prompt directly without a subcommand to run it headless, e.g. `smith "Summarize src/smith.cr"`.

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
    ├── paths.cr             # Resolves ~/.smith (honours SMITH_HOME)
    ├── config.cr            # config.toml discovery, merging & precedence chain
    ├── project_ctx.cr       # SMITH.md & AGENTS.md discovery
    ├── skills.cr            # Skill catalog discovery & $skill / /skill expansion
    ├── session.cr           # Session persistence store (~/.smith/sessions/)
    ├── subagents.cr         # Child agent supervisor & report handling
    ├── llm.cr               # Requires all LLM provider adapters
    ├── tools.cr             # Requires all tool implementations
    ├── llm/
    │   ├── types.cr         # Provider-neutral Request, Response, Message & ToolSpec
    │   ├── provider.cr      # Abstract Provider base class
    │   ├── retry.cr         # Exponential backoff retry handler
    │   ├── openrouter.cr    # OpenRouter API client adapter
    │   ├── ollama.cr        # Ollama API client adapter
    │   ├── anthropic.cr     # Anthropic Messages API client adapter
    │   └── openai.cr        # OpenAI Chat Completions client adapter
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
