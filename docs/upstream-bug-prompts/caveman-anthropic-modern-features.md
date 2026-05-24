# Prompt: contribute a fix to caveman-code for missing Anthropic capability opt-ins

You are an experienced TypeScript developer contributing a bug fix to
the [caveman-code](https://github.com/JuliusBrussee/caveman-code)
project (an MIT-licensed terminal coding agent). Your job: file two
issues (one per bug, since they are independently reproducible and
fixable), then open a single PR that addresses both with a shared
per-model capability table.

You have read+write access to clone, build, test, branch, and push
your own fork. You do NOT have commit access to the upstream repo;
the deliverable is a PR with passing tests.

## Why one PR covers two bugs

Both bugs live in caveman's Anthropic API client. Both manifest only
on specific newer Claude models. Both are "caveman doesn't opt into a
newer Anthropic API feature." The cleanest fix is a per-model
capability table consulted by the request-body builder; that one data
structure addresses both bugs, and a maintainer reviews one well-
scoped PR instead of two overlapping ones.

If review feedback wants them split, splitting is a one-commit
restructure. Default to combined.

## Bug A — Anthropic adaptive-thinking rejection

### Observed symptom

When a user selects an Anthropic Claude model that has been migrated
to the new "adaptive" thinking schema (verified failing:
`claude-opus-4.7`; likely also affects `claude-opus-4.6`,
`claude-sonnet-4.7`, and any future Anthropic model gated on
adaptive thinking) and sends a prompt, Anthropic returns HTTP 400
immediately:

```json
{
  "type": "error",
  "error": {
    "type": "invalid_request_error",
    "message": "\"thinking.type.enabled\" is not supported for this model. Use \"thinking.type.adaptive\" and \"output_config.effort\" to control thinking behavior."
  }
}
```

### Reproducer

Against caveman-code 0.65.2, via GitHub Copilot's Vertex relay (same
shape reproduces against the direct Anthropic API for affected
models):

```bash
caveman --mode rpc --provider github-copilot
> {"id":"1","type":"set_model","provider":"github-copilot","modelId":"claude-opus-4.7"}
< {"id":"1","type":"response","command":"set_model","success":true,...}
> {"id":"2","type":"prompt","message":"hi"}
< {"id":"2","type":"response","command":"prompt","success":true}
< {"type":"agent_start"}
< {"type":"turn_start"}
< {"type":"message_start","message":{"role":"user",...}}
< {"type":"message_end","message":{"role":"user",...}}
< {"type":"message_start","message":{"role":"assistant","model":"claude-opus-4.7",...}}
< {"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error",
                                   "errorMessage":"400 {\"type\":\"error\",...thinking.type.enabled...}"}}
< {"type":"turn_end",...}
< {"type":"agent_end",...}
```

The same prompt against `claude-sonnet-4.5` succeeds, so the issue is
strictly per-model.

### Root cause (best-effort; confirm against current source)

caveman's Anthropic request builder sends:

```json
{
  "model": "claude-opus-4.7",
  "thinking": { "type": "enabled", "budget_tokens": 8000 },
  ...
}
```

Newer Anthropic models (post the "adaptive thinking" rollout) reject
that shape. They want:

```json
{
  "model": "claude-opus-4.7",
  "thinking": { "type": "adaptive" },
  "output_config": { "effort": "medium" }
}
```

or simply omitting the thinking block entirely if no effort control
is needed.

Relevant Anthropic docs:
<https://docs.anthropic.com/en/docs/build-with-claude/extended-thinking>
(check the current section on `thinking.type=adaptive` plus
`output_config.effort` — Anthropic reorganises these pages).

## Bug B — 1M context window not opt-in for Anthropic models that support it

### Observed symptom

Users get the 200k context window on `claude-opus-4.5` /
`claude-opus-4.7` / `claude-sonnet-4.5` even when those models
support a 1M window. caveman never opts into Anthropic's 1M tier.
The UI displays `200k` in the modeline / model picker; long sessions
hit context compaction earlier than they should.

This is silent — there's no error, just an unused capability — which
makes it easy to miss. The user only notices when their context fills
up faster than they expect.

### Reproducer

```bash
caveman --mode rpc --provider anthropic
> {"id":"1","type":"set_model","provider":"anthropic","modelId":"claude-opus-4-5"}
> {"id":"2","type":"get_state"}
< ...response data.model.contextWindow shows 200000, not 1000000...
```

Compare against the Anthropic dashboard / `/v1/models` which shows
the same model with a 1M ceiling when opted in.

### Root cause (best-effort; confirm against current source + Anthropic docs)

Anthropic's 1M-context tier is gated by a request header (and may
also gate on a separate model ID variant depending on when you read
this — Anthropic has flipped between approaches at least once).
Current mechanism (verify against docs at
<https://docs.anthropic.com/en/api/long-context>):

- **Beta header on the same model ID:** `model: claude-opus-4-5` plus
  `anthropic-beta: context-1m-2025-08-07` (or the current beta tag).
- **OR a separate variant model ID** like `claude-opus-4-5-1m`.

A grep of caveman-code 0.65.2 turns up no `anthropic-beta` header
for `context-1m`, and no `1m` variant model IDs in the Anthropic
provider list, so the opt-in is simply not happening.

The UI code already knows how to *display* 1M windows (it formats
them correctly when the model registry reports one — see
`packages/coding-agent/src/modes/interactive/components/model-selector.ts`).
The gap is purely in the request builder + model registry: neither
sends the beta header nor advertises the 1M ceiling for capable
models.

## What you must do

### 1. File two issues, link them together

Issue A — Title: "Anthropic models with adaptive thinking (e.g.
claude-opus-4.7) reject every request with 400". Body: paraphrase
Bug A's Symptom + Reproducer + Root cause. Include the full
errorMessage so the maintainer can grep for it.

Issue B — Title: "Anthropic 1M context window not opted into for
supported models". Body: paraphrase Bug B's Symptom + Reproducer +
Root cause. Cross-link Issue A; mention that you intend to fix both
in a single PR.

Each issue body must be enough that a maintainer can repro without
your fix in 5 minutes.

### 2. Locate the offending code

The Anthropic API client lives in caveman-code's monorepo at:

```
packages/ai/src/anthropic/        ; high probability
packages/agent/src/                ; possible secondary site
```

Search for:

- Bug A: `thinking.*type` / `"enabled"` / `budget_tokens` in the
  Anthropic request-body builder.
- Bug B: `anthropic-beta` header construction; `contextWindow` /
  context-size declarations for the Anthropic model registry.

Both should converge on one or two files. Confirm by tracing what
JSON / headers are actually sent to
`https://api.anthropic.com/v1/messages` (or the equivalent
Vertex / Copilot relay endpoint).

### 3. Implement the fix with a shared capability table

Introduce a small per-model capability lookup. Sketch:

```ts
type AnthropicModelCapabilities = {
  thinkingSchema: "legacy" | "adaptive";  // legacy = {type:"enabled",budget_tokens}
                                          // adaptive = {type:"adaptive"} + output_config.effort
  contextBeta?: string;                    // e.g. "context-1m-2025-08-07"; if set, request 1M.
  contextWindow: number;                   // 200_000 or 1_000_000 etc.
};

const ANTHROPIC_MODEL_CAPABILITIES: Record<string, AnthropicModelCapabilities> = {
  "claude-opus-4-7":   { thinkingSchema: "adaptive", contextBeta: "context-1m-2025-08-07", contextWindow: 1_000_000 },
  "claude-opus-4-6":   { thinkingSchema: "adaptive", contextBeta: "context-1m-2025-08-07", contextWindow: 1_000_000 },
  "claude-opus-4-5":   { thinkingSchema: "legacy",   contextBeta: "context-1m-2025-08-07", contextWindow: 1_000_000 },
  "claude-sonnet-4-5": { thinkingSchema: "legacy",   contextWindow: 200_000 },
  // ...fill in from Anthropic docs / /v1/models...
};
```

The request builder consults this table per request:

```ts
const caps = getCapabilities(modelId);
const body = {
  model: modelId,
  ...buildThinkingBlock(caps.thinkingSchema, thinkingLevel),
  ...otherFields,
};
const headers = {
  ...baseHeaders,
  ...(caps.contextBeta ? { "anthropic-beta": caps.contextBeta } : {}),
};
```

The model registry pulls `contextWindow` from the same table so the
UI's `200k` / `1M` display is automatically right.

#### Thinking-schema mapping

Map the existing caveman `thinkingLevel` axis ↔ Anthropic effort:

```
caveman level   adaptive effort
off             (omit thinking block entirely; do not set output_config.effort)
minimal         low
low             low
medium          medium
high            high
xhigh           high     (Anthropic may not expose a higher tier; check docs)
```

Confirm the accepted `output_config.effort` values from current
Anthropic docs before landing.

#### Acceptable interim fixes

If the maintainer pushes back on the table-based approach, an
acceptable alternative is regex-based gating:

- Bug A: detect `claude-opus-4\.[6-9]` / `claude-sonnet-4\.[6-9]` /
  any future cutoff and switch to the adaptive shape.
- Bug B: same regex set adds the `anthropic-beta: context-1m-*`
  header.

Either way, **leave a comment with a TODO referencing Anthropic's
`/v1/models` capability advertisement**, which would let caveman
discover this dynamically and stop hardcoding the table.

### 4. Add tests

caveman has unit tests under `packages/ai/test/` (or similar).
Add at minimum:

**For Bug A:**
- A test asserting a known-adaptive model produces a request body
  with `thinking.type === "adaptive"` and an `output_config.effort`
  field; no `budget_tokens`.
- A test asserting a known-legacy model (sonnet-4.5) still produces
  `thinking.type === "enabled"` + `budget_tokens`.
- A test that `thinkingLevel === "off"` omits the entire thinking
  block AND the `output_config` field for both schemas.

**For Bug B:**
- A test asserting the request to a 1M-capable model includes the
  `anthropic-beta: context-1m-<date>` header.
- A test asserting the request to a non-1M model does *not* include
  that header.
- A test asserting the model registry reports `contextWindow:
  1_000_000` for 1M-capable models and `200_000` otherwise.

Run the existing test suite to make sure nothing else regressed:

```bash
cd packages/ai && pnpm test   # or whatever the workspace uses
```

### 5. Open the PR

- Branch name: `fix/anthropic-modern-capabilities`
- PR title: `fix(ai/anthropic): adaptive thinking + 1M context opt-in for opus-4.5+`
- PR body must include:
  - Links to both issues.
  - The capability table you landed on.
  - Before/after for Bug A: RPC trace showing the 400 disappearing.
  - Before/after for Bug B: `get_state` showing 1M context window
    after the fix; ideally a `curl` snippet showing the
    `anthropic-beta` header in the outgoing request.
  - Confirmation that previously-working models (sonnet-4.5, haiku,
    older opus) still behave identically.

### 6. Be helpful in review

If the maintainer prefers a different design (e.g. capability
discovery via `/v1/models`, or extracting the schema into a
versioned provider config), accommodate them. Don't argue the
bikeshed.

If the maintainer wants the bugs split into separate PRs, factor out
the capability table into a small first commit, then commit Bug A on
top, then Bug B. Split is straightforward post-hoc.

## Out of scope

- Do NOT change cavemacs (the downstream Emacs frontend that
  discovered Bug A). That repo has its own workaround: it surfaces
  upstream errors to the user instead of swallowing them.
- Do NOT touch other provider clients (OpenAI, Google, etc.) unless
  the maintainer asks you to harmonize the design across providers.
- Do NOT add new features beyond making the existing UX work
  correctly for capable models.

## Definition of done

- Two issues filed, both triaged (maintainer ack or "approved for
  PR" label) and cross-linked.
- PR opened, CI passing, tests added per item 4.
- A user can run `caveman --provider anthropic --model
  claude-opus-4-7 -p "hello"` and get a real response back.
- A user running `caveman --provider anthropic --model
  claude-opus-4-5` sees the 1M context window in the modeline and
  picker, and can actually use a context that exceeds 200k tokens.
- Maintainer review addressed; either merged, or you've handed the
  PR off cleanly with a written summary of remaining work.
