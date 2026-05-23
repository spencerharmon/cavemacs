# Prompt: contribute a fix to caveman-code for Anthropic thinking-config rejection

You are an experienced TypeScript developer contributing a bug fix to
the [caveman-code](https://github.com/JuliusBrussee/caveman-code)
project (an MIT-licensed terminal coding agent). Your job: file an
issue, then open a PR that fixes a bug where newer Anthropic Claude
models reject every request caveman sends because of an outdated
"thinking" parameter shape.

You have read+write access to clone, build, test, branch, and push
your own fork. You do NOT have commit access to the upstream repo;
the deliverable is a PR with passing tests.

## Background — observed bug

When a user selects an Anthropic Claude model that has been added to
caveman recently (verified failing: `claude-opus-4.7`; likely also
affects `claude-opus-4.6`, `claude-sonnet-4.7`, and any future
Anthropic model that opts into the new "adaptive" thinking schema)
and sends a prompt, Anthropic returns HTTP 400 immediately:

```json
{
  "type": "error",
  "error": {
    "type": "invalid_request_error",
    "message": "\"thinking.type.enabled\" is not supported for this model. Use \"thinking.type.adaptive\" and \"output_config.effort\" to control thinking behavior."
  }
}
```

Reproducer (against caveman-code 0.65.2, via GitHub Copilot's Vertex
relay; the same shape error reproduces against the direct Anthropic
API for the affected models):

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

Note the assistant message has no content, stopReason "error", and
the upstream Anthropic 400 in errorMessage.

The same prompt against `claude-sonnet-4.5` succeeds, so the issue is
strictly per-model, gated on whether Anthropic has migrated that
model to the "adaptive thinking" API.

## Root cause (best-effort, you should confirm)

caveman's Anthropic API client sends a top-level request body
containing something like:

```json
{
  "model": "claude-opus-4.7",
  "thinking": { "type": "enabled", "budget_tokens": 8000 },
  ...
}
```

Anthropic's newer models (post the "adaptive thinking" rollout) reject
that shape. They want either:

```json
{
  "model": "claude-opus-4.7",
  "thinking": { "type": "adaptive" },
  "output_config": { "effort": "medium" }
}
```

or simply omitting the thinking block entirely if effort control is
not needed.

The relevant docs are at
<https://docs.anthropic.com/en/docs/build-with-claude/extended-thinking>
(and whatever section currently describes `thinking.type=adaptive`
plus `output_config.effort` — Anthropic moves these around). Compare
the request body caveman is building to the documented schema for
the model in question.

## What you must do

### 1. Open an issue first

Title: "Anthropic models with adaptive thinking (e.g. claude-opus-4.7)
reject every request with 400"

Body: paraphrase the Background section above. Include the reproducer.
Link to the cavemacs issue/discussion that surfaced it if one exists
yet (search the user's `spencerharmon/cavemacs` repo for "thinking";
if no public report exists, just reference the user-facing symptom).

The issue body must be enough that a maintainer can repro without
your fix in 5 minutes. Confirm at least one Anthropic model still
works (e.g. sonnet-4.5) and at least one Anthropic model fails (e.g.
opus-4.7).

### 2. Locate the offending code

The Anthropic API client lives in caveman-code's monorepo at:

```
packages/ai/src/anthropic/        ; high probability
packages/agent/src/                ; possible secondary site for request shaping
```

Search for `thinking.*type` / `"enabled"` / `budget_tokens` / similar
in the Anthropic request-body builder. The exact file is whichever
one constructs the JSON sent to `https://api.anthropic.com/v1/messages`
(or the equivalent Vertex / Copilot relay endpoint).

Confirm: which models use the legacy `{type: "enabled"}` shape, and
which need the new `{type: "adaptive"}` shape? Two ways to figure
this out:

- Anthropic's `/v1/models` endpoint may expose a per-model capability
  flag. Check.
- Anthropic's docs may list the cutoff (model release date / version).
- Worst case: hardcode a list of known-adaptive-only models with a
  TODO comment to refactor when caveman gains a model-capabilities
  table.

### 3. Implement the fix

Strongly preferred design: a per-model capability table or feature
flag that drives whether the request body uses `{type: "enabled",
budget_tokens: N}` or `{type: "adaptive"}` plus `output_config.effort`.

Acceptable interim fix: detect models matching `claude-opus-4.[6-9]`,
`claude-sonnet-4.[6-9]`, etc., and switch to the new shape for those.

Map the existing `thinking_level` ↔ `effort` axis cleanly:

```
caveman level   adaptive effort
off             (omit thinking block entirely)
minimal         low
low             low
medium          medium
high            high
xhigh           high     (Anthropic may not expose a higher tier)
```

Confirm Anthropic's accepted effort values from current docs before
landing.

### 4. Add tests

caveman has unit tests under `packages/ai/test/` (or similar).
Add:

- A test asserting that a known-adaptive model produces a request
  body with `thinking.type === "adaptive"` and an `output_config.effort`
  field (no `budget_tokens`).
- A test asserting that a known-legacy model (sonnet-4.5) still
  produces the old `thinking.type === "enabled"` shape.
- A test that `thinking_level=off` omits the thinking block entirely
  for both code paths.

Run the existing test suite to make sure nothing else regressed:

```bash
cd packages/ai && pnpm test   # or whatever the workspace uses
```

### 5. Open the PR

- Branch name: `fix/anthropic-adaptive-thinking`
- PR title: `fix(ai/anthropic): use adaptive thinking schema for opus-4.7+`
- PR body must include:
  - Link to your issue.
  - Before/after curl invocations or RPC traces showing the fix.
  - The mapping table above.
  - A brief note on which models the fix changes behavior for.
  - Confirmation that older models still work unchanged.

### 6. Be helpful in review

If the maintainer pushes back on the per-model table approach and
prefers a different design (e.g. capability negotiation via
`/v1/models`, or extracting the thinking schema into a versioned
provider config), accommodate them. Don't argue the bikeshed.

## Out of scope

- Do NOT change cavemacs (the downstream Emacs frontend that
  discovered the bug). That repo has its own workaround: it now
  surfaces upstream errors to the user instead of swallowing them.
- Do NOT touch other provider clients (OpenAI, Google, etc.) unless
  the maintainer asks you to harmonize the design across providers.
- Do NOT add a new feature; this is strictly a bug fix.

## Definition of done

- Issue filed and triaged (maintainer ack or "approved for PR" label).
- PR opened, CI passing, tests added.
- A user can run `caveman --provider <anthropic-or-relay> --model
  claude-opus-4.7 -p "hello"` and get a real response back.
- Maintainer review addressed; either merged, or you've handed the
  PR off cleanly with a written summary of remaining work.
