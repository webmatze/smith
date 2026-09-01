# Changelog

All notable changes to smith. The format follows [Keep a Changelog](https://keepachangelog.com/), and the project adheres to [Semantic Versioning](https://semver.org/).

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
