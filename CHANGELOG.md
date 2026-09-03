# Changelog

All notable changes to smith. The format follows [Keep a Changelog](https://keepachangelog.com/), and the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **`/model` switches the model mid-session**: bare it reports the model and provider in use, with a name it switches the model from the next request onward — the provider client, its API key and its connection stay as they are, which is all `-m` ever decided at startup. The new model is written to the session straight away, so `smith resume` comes back on it, and subagents spawned afterwards follow it. `--max-budget-usd` now adds each turn up at the rates in force when that turn was billed, so a switch cannot re-price money already spent. No allow-list stands in the way of a model released next week — a name must be a single word that is not a flag, a path or a provider, and anything else the provider rejects at the next request as an ordinary turn error. One session still records one model, so a session that switched is reported under the model it ended on by `smith stats` and the `COST` column (#94).
- **`smith skills list` and `smith agents list`**: the two catalogs smith already builds are now readable. `skills list` prints every skill with its origin file, its description and any file of the same name it shadows, and — this is the point — names each `SKILL.md` that did not read as written: a `---` block that is never closed, a byte-order mark in front of it, or a line that is not `key: value` (a `tools:` over a YAML list arrives as no value at all). Such a file still loads, but under its directory name and without its description, which until now was invisible until `$skill-name` quietly failed to expand. `agents list` prints each definition with its path, description, provider, model, mode and effective tool list, so a definition that names no `tools` shows what its mode implies rather than a blank; the same header check warns for agent definitions too, through the channel they already warn on (#93).

### Fixed

- **A skill or agent file smith cannot read no longer takes smith with it.** Both catalogs are built before the CLI knows which command was asked for, so a single `SKILL.md` that could not be opened, or one saved as Latin-1 rather than UTF-8, aborted every command with a stack trace — `smith -v` included. Each is now reported by path and reason and skipped (#93).

## [0.4.0] — 2026-09-02

### Added

- **Chat commands with autocomplete**: new built-ins `/help`, `/clear`, `/sessions`, `/resume <session>` and `/quit` join `/plan`, `/normal`, `/rewind`, `/context` and `/rename`. In the fullscreen UI, typing `/` opens a popup that filters built-ins and skills as you type — `↑`/`↓` select, `Tab` completes, `Enter` runs, `Esc` dismisses. `/resume` switches sessions inside the running loop; `/clear` wipes the context and the screen.
- **MCP over HTTP**: entries in `mcp.json` with a `type` of `http`/`sse` or a bare `url` connect via Streamable-HTTP POST instead of spawning a subprocess — JSON and SSE answers alike, the session id the server assigns carried on every later request, bearer tokens from the environment via `${VAR}` header expansion. Everything the stdio path already had applies unchanged: approval gate, untrusted marking, restart-once, per-call timeout (#84).
- **`smith stats`**: aggregates cost and tokens across all saved sessions from the index alone — a grand total, a prompt/completion/cache split and a per-provider/model breakdown. Unknown rates add tokens but show `n/a`, never a guess; `[pricing]` overrides from config apply (#85).
- **Session hygiene**: `smith sessions delete <ref>…` removes sessions by name or id — file, directory and index entry — and `smith sessions prune` drops sessions older than `--older-than` (30d default) while keeping `--keep-last` N; both support `--dry-run`. The newest session is never pruned, and `[sessions] retention_days` prunes at startup (#82).
- **Cost per session**: `smith sessions` shows a `COST` column per row, priced from the index and honouring `[pricing]` overrides; unknown models and entries predating usage tracking show `n/a` (#83).

### Changed

- **The fullscreen UI now sits on anvil**: text, editor and popup layers, the event loop, terminal handling and the live region come from the published [anvil](https://github.com/webmatze/anvil) and termisu libraries — smith keeps the domain: what keys mean while a popup is open, the status line, the event-stream-to-blocks renderer and the gates. `src/smith/ui` shrank from 2 699 to 1 392 lines.

## [0.3.0] — 2026-09-01

### Added

- **Bash Sandbox (macOS)**: `bash` is confined to the project via `sandbox-exec` — writes outside it fail, reads can be denied per path, and confined commands can skip the approval prompt entirely (`--yes` stays meaningful). Configured via `[sandbox]` in `config.toml`; `smith sandbox` shows what is in force (#79).
- **Image & PDF input, on three paths**: `@screenshot.png` attaches the file itself (#72), a tool result can carry an image (#73), and an MCP server may answer with one (#78). The format is decided from the magic bytes, not the extension or a claimed `mimeType`; PDFs go to Anthropic natively.
- **Raw transcript log**: every message is appended to `transcript.jsonl` beside the session before compaction can touch it — the untouched record of a run (#58).
- **Context compaction, deeply and rarely**: instead of shallowly every turn, compaction now acts in stages — stale thinking, superseded reads and staged caps reclaim context gently (#55, #58).
- **Prompt caching through OpenRouter**: caching works on the OpenRouter route to an `anthropic/` model too, with two breakpoints instead of three (#70).
- **Releases ship binaries**: tags now build signed release binaries for Linux and macOS in CI and attach them to the GitHub release.

### Changed

- **Checkpoints are anchored to a message id**, not a position in the transcript — rewinding stays correct across compaction (#59).
- **`bash` output names the git boundary** where checkpoints cannot reach, and the git root is recognised when `.git` is a file (worktrees) (#75, #77).

### Fixed

- `read_file` refuses binary files instead of inlining their bytes (#67).
- Headless runs get the checkpoints they already had a session for (#68).
- Dropped the headless branch `bash` job logs never took (#71).
- The Makefile builds on Linux too.

## [0.2.0] — 2026-08-08

Providers, permissions and a fullscreen UI — see the release notes.

## [0.1.0] — 2026-08-05

Initial release.
