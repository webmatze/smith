# Changelog

All notable changes to smith. The format follows [Keep a Changelog](https://keepachangelog.com/), and the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **`smith update` replaces the binary from the newest release**: it reads the latest tag from the GitHub API, compares it against `Smith::VERSION`, downloads the archive for this platform over HTTPS, verifies its SHA-256 against the release's new `SHA256SUMS`, and renames the new file over the old one in the same directory, which is the only replacement a running executable survives. `--check` reports and changes nothing. The download runs through the same post-DNS SSRF guard `web_fetch` uses, plus three rules of its own: a non-https URL is refused rather than upgraded, since it came from an API answer and not from a human; the redirect off `github.com` to `objects.githubusercontent.com` **is** followed, where `web_fetch` refuses a cross-host hop, so an allow-list of GitHub's own hosts takes over that job and is applied afresh on every one of at most five hops; and a `smith` member that is not a plain regular file is refused, because a symlinked one would be chmod'ed and renamed straight through the link. Releases now carry a `SHA256SUMS`, and one that does not is refused unless it predates this feature or `--allow-unverified` is passed. Release builds are stamped as such at compile time, so a `make build` from a working tree refuses to overwrite itself instead of destroying a build nothing can reproduce — as do a Homebrew or Nix install, a distribution directory, and a directory the current user cannot write, each naming the command to run instead. A build newer than the newest release is never downgraded (#96).

- **`/model` switches the model mid-session**: bare it reports the model and provider in use, with a name it switches the model from the next request onward — the provider client, its API key and its connection stay as they are, which is all `-m` ever decided at startup. The new model is written to the session straight away, so `smith resume` comes back on it, and subagents spawned afterwards follow it. `--max-budget-usd` now adds each turn up at the rates in force when that turn was billed, so a switch cannot re-price money already spent. No allow-list stands in the way of a model released next week — a name must be a single word that is not a flag, a path or a provider, and anything else the provider rejects at the next request as an ordinary turn error. One session still records one model, so a session that switched is reported under the model it ended on by `smith stats` and the `COST` column (#94).
- **`smith skills list` and `smith agents list`**: the two catalogs smith already builds are now readable. Both print each entry with its origin file and any file of the same name it shadows, and a warning about a file that lost a name clash names the file that won rather than reading as though the entry in use were broken. `skills list` prints every skill with its description, and — this is the point — names each `SKILL.md` that did not read as written: a `---` block that is never closed, a byte-order mark in front of it, or a line that is not `key: value` (a `tools:` over a YAML list arrives as no value at all). Such a file still loads, but under its directory name and without its description, which until now was invisible until `$skill-name` quietly failed to expand. `agents list` prints each definition with its path, description, provider, model, mode and effective tool list, so a definition that names no `tools` shows what its mode implies rather than a blank; the same header check warns for agent definitions too, through the `warn_io` they already warn on (#93).
- **`smith sessions export <ref>`**: takes a run with you — Markdown on stdout by default, `--json` for the structured log, `--out <path>` for a file. The reference resolves the way `resume` and `sessions delete` resolve one, and the export reads the raw `transcript.jsonl` in preference to the compaction-shortened session file, naming its source and both message counts so a disagreement is visible. Attachments render as placeholders rather than base64, tool calls and thinking are abbreviated, non-UTF-8 and control bytes from tool output are scrubbed so the export stays text, unknown rates print `n/a`, and damage degrades: a broken index, an unreadable transcript line or a missing session file cost a warning, not the export. Nothing on the path builds a provider or needs an API key (#95).

### Fixed

- **A session reference is a name or an id, never a path**: `File.join` defused an absolute path but carried `..` straight through, so a crafted reference such as `../../notes` resolved to a directory outside the sessions tree — readable by the new export and, worse, removable by `smith sessions delete`, which deletes the directory it resolves. Refused now wherever a reference becomes a path — the filesystem lookup and the removal itself — and `smith rename` will not create a name of that shape any more. Matching an id or a name is untouched, so a session an earlier release let you call `feat/export` still resumes, exports and deletes by that name (#95).
- **One damaged index entry no longer hides every other session**: `index.json` was parsed as a single array, so a half-written or hand-edited entry made the whole file unreadable — no resume by name, no `sessions` listing, no cost column, no `stats`. Entries are parsed one at a time now; a damaged one costs its own session and the rest stay reachable. `smith sessions`, `smith stats` and `smith sessions export` each name what they could not read, because a listing or a total that is quietly one session short is worse than an error (#95).
- **A skill or agent file smith cannot read no longer takes smith with it.** Both catalogs are built before the CLI knows which command was asked for, so a single unreadable file aborted every command with a stack trace — `smith -v` included — and a named pipe in place of a `SKILL.md` hung it with nothing on screen at all. Permissions, bytes that are not UTF-8, a directory, a symlink loop and a FIFO are each now reported by path and reason and skipped (#93).

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
