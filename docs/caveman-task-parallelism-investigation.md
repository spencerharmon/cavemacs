# Investigation prompt: `task` tool serializes when it should parallelize

Hand this file to an agent working in the **caveman-code** repo
(`/home/spencer/git-repos/JuliusBrussee/caveman-code`), NOT cavemacs.
The bug is in the harness, not in any downstream project.

## Context

caveman-code's coding agent exposes a `task` tool for delegating to
subagents (`implementer`, `explore`, `reviewer`, etc.). The tool's
documented modes are:

- `single`  — one `{agent, task}` (per current tool description)
- `parallel` — `tasks: [{agent, task}, ...]` up to 7 in one call
- `chain`   — sequential `[{agent, task}, ...]` with `{previous}` substitution

The intent (per docs) is that `parallel` fans out concurrently and a
parent can dispatch independent units of work without blocking.

## Observed behaviour

During a real session in the cavemacs repo on 2026-05-24 a parent
agent tried to fan out:

1. M13 (UI work in `cavemacs-render.el`) → `implementer` subagent in
   a worktree.
2. Busy-flag audit + M14 + C-a bugfix → driven on the main branch by
   the parent itself.

Parent issued ONE `task` call with `agent: implementer` for M13 as a
standalone tool invocation, then waited. The subagent ran for ~4
minutes (22:30 → 22:34 wall clock). The parent's next assistant turn
("M13 done in worktree. Now busy-flag + M14 + C-a here.") was emitted
AFTER the subagent's `completed: exit 0` event. No interleaved parent
work happened during the subagent run.

The user expected parent work and subagent work to overlap. They did
not.

Additionally, the parent's first attempt at the `task` call was
rejected with a schema error:

```
Validation failed for tool "task":
  - mode: must be equal to constant
  - mode: must be equal to constant
  - mode: must match a schema in anyOf
Received arguments: { "mode": "single", "agent": "implementer", ... }
```

The tool's own documentation string in that runtime listed `mode`
values as `single | parallel | chain`, but the JSONSchema `anyOf`
accepted only `plan` and `auto`. So the tool's self-description and
its schema disagree.

## Hypotheses to investigate (in priority order)

1. **`task` is synchronous per call by design.** A single `task` tool
   invocation blocks the parent's tool loop until the child reports
   `completed`. Concurrency is only achievable by emitting multiple
   tool calls in a single assistant turn (parallel tool-call block),
   or by passing `tasks: [...]` inside one call. If true: this is a
   documentation gap, not a code bug — the prose "up to 7 in one
   call" is correct but the implication that *separate* `task` calls
   in successive turns run concurrently is wrong/unstated.

2. **The `mode` enum is stale.** The schema says
   `mode ∈ {plan, auto}` but the tool prose says
   `mode ∈ {single, parallel, chain}`. One of them is from an older
   API. Decide which is current, fix the other. If `single` /
   `parallel` / `chain` were renamed/removed, the docstring must
   reflect that and the parallel path needs a new trigger
   (probably: presence of `tasks` array vs. `task` string).

3. **Even `tasks: [...]` fan-out may be serial under the hood.** If
   the dispatcher iterates the array with `await child()` instead of
   `Promise.all(children.map(...))`, "parallel" mode is also serial
   despite the name. Worth grepping for the dispatch site.

4. **Streaming/await mismatch in the parent's tool-loop.** Even with
   correct child concurrency, if the parent's tool-result handler
   awaits each `task` call's final report before yielding control
   back to the model, the model can't issue further calls
   concurrently. The fix is to let the parent emit additional tool
   calls (or assistant text) while a `task` is still in flight,
   which usually means switching from request-response to a
   streaming/event model for tool results.

## Where to start in caveman-code

```
packages/coding-agent/src/
  tools/                    # tool definitions; find `task`
  modes/rpc/                # RPC mode dispatch (cavemacs uses this)
  agents/                   # subagent runner; how children are spawned
```

Grep targets:
- `name:\s*['"]task['"]` or `id:\s*['"]task['"]` for the tool def.
- The JSONSchema for `task` (the `mode` enum lives there).
- The dispatch function that consumes `tasks: [...]` — check whether
  it uses `Promise.all` / `Promise.allSettled` vs. a `for ... await`
  loop.
- The parent's tool-result plumbing — does a pending tool call block
  the next model turn, or can the model interleave?

## Reproduction

You don't strictly need a repro to read the code, but if you want
one:

1. From any project, ask the agent: "Run two `task` calls in two
   separate turns: first an `explore` of `src/`, then an
   `implementer` that touches one file. Time them."
2. Observe the parent's `completed` events. If they are strictly
   sequential and total wall-clock = sum of children, the parent
   serializes turns. If total ≈ max(child times), it parallelizes.
3. Then repeat with ONE `task` call containing
   `tasks: [{agent: explore, ...}, {agent: implementer, ...}]`.
   Compare timings to (1).

## Deliverables

- A short writeup of which hypothesis is correct.
- A patch that EITHER:
  - makes separate-turn `task` calls genuinely concurrent (with a
    poll/await verb or streamed tool results), OR
  - reconciles the docs + schema so users understand they MUST
    batch with `tasks: [...]` in one call, AND verifies the batched
    path actually runs children in parallel.
- Whatever subset of mode-enum drift (`single` / `parallel` /
  `chain` vs. `plan` / `auto`) is real, fixed and documented.

## Non-goals

- Don't touch cavemacs. It only surfaced the bug; nothing in it
  needs to change.
- Don't conflate this with cavemacs's M12 "worker dispatch" plan
  item. That's about cavemacs UI for caveman's RPC worker verbs in
  the shell buffer (`& prompt` prefix). It is unrelated to harness
  subagent fan-out.
