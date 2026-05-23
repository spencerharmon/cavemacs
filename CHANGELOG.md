# Changelog

All notable changes to cavemacs will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.0] — initial release

First public version. Implements the full plan.org milestone set
(M0–M8) for talking to `caveman --mode rpc` from Emacs.

### Added
- `cavemacs-rpc.el` — strict LF-delimited JSONL transport for the
  caveman RPC protocol (validated against caveman-code 0.65.2). Handles
  request/response correlation, streamed events, and the
  `extension_ui_request` interactive-prompt channel.
- `cavemacs-shell-mode` — chat buffer with read-only rendered output
  above a multi-line input area, modeline state, and full keymap.
- `cavemacs-render.el` — turn/message/tool overlays, streamed delta
  rendering, optional markdown font-lock, per-run token/cost footer.
- `cavemacs-tools.el` — `confirm` / `select` / `input` / `editor` /
  `notify` UI handlers backed by `read-char-choice` /
  `completing-read` / `read-string` / a popup edit buffer.
- `cavemacs-session.el` — per-project session enumeration backed by
  caveman's own `~/.cave/agent/sessions/` JSONL files, plus a
  `tabulated-list-mode` browser with resume / delete / new actions.
- `cavemacs-commands.el` — slash-command discovery via `get_commands`
  and `completing-read` based picker.
- `cavemacs-cavekit.el` — transient menu for cavekit's `/ck:spec`,
  `/ck:build`, `/ck:check`.
- `cavemacs-cavemem.el` — `/memory search` / `/memory save` helpers,
  viewer launcher.
- `cavemacs-flags.el` — `C-c C-o` transient for mid-session model /
  thinking-level switching, autopilot toggle, manual compaction.
- ERT tests: 13 unit + render tests, 1 live-caveman integration test.
- GitHub Actions CI matrix (Emacs 30.1 / 30.2 / snapshot on Linux +
  macOS).
- `plan.org` capturing the full design rationale.
- `spike/` — the M0 spike scripts that validated the protocol live
  before the package was written.

### Known limitations
- No daemon-mode transport (subprocess-per-buffer only).
- Tool result diffs rendered as plain text, no `diff-mode` overlay.
- Image input not exposed.
- Worker dispatch (`& prompt`) not implemented.
