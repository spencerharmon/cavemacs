# AGENTS.md — guidance for AI coding agents working on cavemacs

This file is read by AI agents (Claude Code, caveman-code, Codex, etc.)
when they're asked to modify this repository. It documents the
workflows and pitfalls that have bitten us during development.

## TL;DR

1. **Always pull the user's straight.el clone before asking them to
   test your changes.** The single biggest source of confusion in
   this project has been "I rebuilt and it still doesn't work" —
   because `straight-rebuild-package` does not `git pull`. It only
   recompiles existing source.
2. Run the unit + render test suite after every change.
3. The live integration test costs real LLM tokens. Run it sparingly,
   and don't run it inside an automated loop.
4. Never use `transient` macros at file top-level — wrap them in
   `(condition-case ... (eval '(transient-define-prefix ...) t) ...)`
   so a transient version mismatch can't break package loading.

## Version bump on every reload-required push (MANDATORY)

Every release (= every push the user must reload Emacs to test) MUST
bump `cavemacs-version` (PATCH) in `cavemacs.el`. The version is
shown in the pretty header-line as `cavemacs X.Y.Z`; the user uses
it to visually confirm the new code is loaded. Without a bump the
user cannot tell stale-vs-fresh and we re-enter the
"rebuilt-but-still-broken" failure mode this whole doc exists to
prevent.

Current baseline: see `(defconst cavemacs-version ...)` in
`cavemacs.el`. Pre-1.0; bump PATCH only.

### The full release / test loop

For every code change the user needs to reload to test, do ALL of:

1. Make the change.
2. Run unit + render tests (`emacs --batch ...`, see Testing
   section). They must pass.
3. Byte-compile clean (no warnings).
4. Bump PATCH in the `(defconst cavemacs-version "X.Y.Z" ...)` form
   in `cavemacs.el`. Also update the `;; Version:` header comment
   at the top of `cavemacs.el` to match.
5. `git add` + `git commit` (conventional-commit style; explain WHY
   and any non-obvious mechanics).
6. `git push` to `origin/main`.
7. Refresh the user's straight clone so they're not running stale
   code, AND rebuild so the .elc files match the new source:
   ```bash
   cd ~/.emacs.d/straight/repos/cavemacs && git pull --ff-only
   emacsclient -e '(straight-rebuild-package "cavemacs")'
   ```
   (emacsclient runs inside the user's live Emacs where straight is
   already bootstrapped; a `emacs --batch` invocation can't `require
   'straight` without re-bootstrapping.)

   straight only rebuilds when source mtime is newer than build
   artifacts; `git pull` sets the mtime, but running an explicit
   rebuild guarantees the .elc files are current before the user
   restarts. Without this step the user can restart into stale
   byte-compiled code even though the .el source is fresh.
8. Verify parity: the SHA from `git log --oneline -1` in the user's
   straight clone must match `origin/main`.
9. Tell the user: "Restart Emacs. Header-line should read
   `cavemacs X.Y.Z` (the new PATCH)." If they report the old PATCH,
   they're still on stale code.

Doc-only changes (README, AGENTS.md, plan.org) and test-only
changes that don't affect runtime do NOT need a version bump or a
straight-clone refresh. Everything else does.

## Refresh-before-test workflow (MANDATORY)

`straight.el` is the package manager users install cavemacs with.
By design, **straight does NOT auto-pull from the remote**; it only
rebuilds packages when local source mtime is newer than build
artifacts.

If you push a commit and tell the user "try it now," and they do
`M-x straight-rebuild-package cavemacs` + restart Emacs, they will
still be running the OLD code unless they explicitly pulled first.

### After every push, before asking the user to test:

```bash
# Update the user's local straight clone to match origin/main.
cd ~/.emacs.d/straight/repos/cavemacs && git pull --ff-only
```

Or, from inside the user's Emacs:

```elisp
M-x straight-pull-package RET cavemacs RET
M-x straight-rebuild-package RET cavemacs RET   ;; usually auto on next start
```

Then **the user restarts Emacs**. (`unload-feature` / `load-file`
inside a running Emacs is unreliable for cavemacs because of
process filter closures and `defvar-local` capture.)

### Verifying the user is running the right code

Before debugging anything they report:

```bash
cd ~/.emacs.d/straight/repos/cavemacs && git log --oneline -1
gh api repos/spencerharmon/cavemacs/commits/main --jq '.sha[:7]'
```

If those SHAs differ, the user is running stale code. Always
confirm parity before assuming a fix didn't work.

This caught us multiple times during initial development. Don't
repeat the mistake.

## Testing

```bash
# Byte-compile (must be warning-free)
emacs --batch -L . \
  --eval "(dolist (f (directory-files \".\" t \"^cavemacs.*\\\\.el$\")) \
            (byte-compile-file f))"

# Unit + render tests (no subprocess)
emacs --batch -L . \
  -l tests/cavemacs-rpc-test.el \
  -l tests/cavemacs-render-test.el \
  -l tests/cavemacs-commands-test.el \
  -f ert-run-tests-batch-and-exit

# Integration tests (require caveman binary + authenticated provider;
# real LLM tokens spent)
emacs --batch -L . \
  -l tests/cavemacs-integration-test.el \
  -f ert-run-tests-batch-and-exit
```

Run unit + render after every change. Run integration when changing
RPC transport, render, or shell-mode logic. Skip integration when
the change is doc-only.

## Known traps

### 1. Transient version mismatch

Emacs 30.2 ships transient `0.7.2.2` built-in. straight.el typically
installs `0.13+` from MELPA. If transient was already loaded by
*another* package (vc, magit) before straight could shadow it, the
built-in 0.7 wins. cavemacs files compiled against 0.13's macro
expansion will then call `transient--set-layout` (a 0.13-only
function) → `void-function` error at load.

**Defensive pattern** (used in `cavemacs-cavekit.el` and
`cavemacs-flags.el`):

```elisp
(defvar cavemacs-cavekit--transient-ok
  (condition-case nil
      (progn (require 'transient)
             (eval '(transient-define-prefix ...) t)
             t)
    (error nil)))

;; Then dispatch with completing-read fallback.
```

Never put a top-level `(transient-define-prefix ...)` in a file
without that wrap.

### 2. `save-excursion` in render macros

`cavemacs-render--at-output` looks like it should restore point
cleanly, but `save-excursion`'s saved-point marker has
insertion-type nil. If point was at `point-max` when the macro
fired, and the body inserts text *before* point, post-restore point
is now in the middle of the rendered text, not at the new
`point-max`. `(eobp)` returns nil and `cavemacs-shell-send-or-newline`
falls into its `(newline)` branch — RET stops working.

The macro now snapshots "was at point-max" before the body and
advances point + every live window-point to the new `point-max`
afterward. **Do not break this invariant.** Window-point matters
because users displaying the buffer in a window have a separate
window-point that the buffer's `point` doesn't always track.

### 3. Two markers, not one

The shell buffer uses two markers for the input area:

- `cavemacs-shell--prompt-marker` (insertion-type `t`): just before
  the separator + `>` prefix. Rendered output inserts here and
  pushes the marker forward, so output piles up *above* the
  separator while the prompt stays pinned at the bottom.
- `cavemacs-shell--input-start-marker` (insertion-type nil): right
  after the `>` prefix. User typing past it does not advance the
  marker. `input-text` is the substring between this marker and
  `point-max`.

A single-marker scheme cannot satisfy both roles. Don't refactor
back to one marker.

### 4. RPC `prompt` vs. local slash-command dispatch

Caveman's built-in TUI slash commands (`/help`, `/model`,
`/compact`, etc.) are **not** processed by the RPC `prompt` handler.
They were a TUI input-layer feature. If you send `/help` as a
`prompt`, the LLM just answers it in plain English instead of doing
anything mechanical.

`cavemacs-commands-dispatch` intercepts known built-ins and routes
them to their direct RPC equivalents (`set_model`, `compact`,
`new_session`, etc.). Unknown slashes fall through — caveman's
RPC `prompt` *does* run user-installed extension/prompt/skill
commands, so we let those pass.

If you add a new slash-command built-in, add it to
`cavemacs-commands--builtins` AND a test in
`tests/cavemacs-commands-test.el` that asserts dispatch returns
non-nil for it.

### 5. Caveman protocol is NOT JSON-RPC 2.0

`caveman-code/docs/api.md` describes a JSON-RPC 2.0 protocol with
methods like `session.create` / `session.prompt`. **That is wrong**
relative to the actual binary. The real protocol is documented in
`caveman-code/packages/coding-agent/src/modes/rpc/rpc-types.ts`:

- Commands: `{"id"?, "type": <verb>, ...}` with verbs `prompt`,
  `new_session`, `abort`, `fork`, `compact`, `get_state`,
  `get_commands`, `set_model`, etc.
- Responses: `{"id"?, "type": "response", "command": <verb>,
  "success": <bool>, "data"?, "error"?}`.
- Events: AgentEvent envelope with `agent_*` / `turn_*` /
  `message_*` / `tool_execution_*` / etc.
- UI prompts (tool approvals, file pickers, ...) flow through
  `extension_ui_request` / `extension_ui_response`.

Strict LF-delimited JSONL. Trim trailing `\r` for tolerance. One
caveman process == one session.

When unsure, read the TypeScript source — `docs/api.md` is
misleading.

## Code layout

```
cavemacs.el           top-level facade + M-x cavemacs / -new / -continue
cavemacs-config.el    customs, binary lookup, CLI arg builder
cavemacs-rpc.el       JSONL transport (framing, correlation, UI handlers)
cavemacs-project.el   git/project.el root detection
cavemacs-render.el    AgentSessionEvent renderer with overlays + markdown
cavemacs-shell.el     cavemacs-shell-mode major mode + buffer lifecycle
cavemacs-tools.el     extension_ui_request handler (confirms/inputs/etc.)
cavemacs-session.el   per-project session browser (tabulated-list)
cavemacs-commands.el  slash-command discovery + dispatch + CAPF
cavemacs-cavekit.el   transient menu for cavekit /ck:spec/build/check
cavemacs-cavemem.el   /memory helpers + viewer launcher
cavemacs-flags.el     C-c C-o transient (pick model, cycle thinking, etc.)
```

Dependency direction is a DAG; do not introduce cycles. If module A
needs symbols from module B but B already depends on A (directly or
transitively), use `(declare-function ...)` and `(defvar ...)`
forwards instead of adding a `require`.

## Commit style

Follow conventional commits (`feat:`, `fix:`, `docs:`, `test:`,
`refactor:`, `chore:`). Body explains the *why* and any non-obvious
mechanics; the diff shows the *what*.

When fixing a bug whose original diagnosis was wrong, the commit
message should briefly note what the wrong diagnosis was, so future
readers don't re-investigate down the same dead end.

## When in doubt

Read `plan.org`. It documents every milestone (M0–M8, M10), every
regression (R1, R2), and the postmortems explaining why we chose
the approaches we chose.
