---
name: codex-claude-loop
description: Use when driving a gated build loop where Claude orchestrates and Codex CLI implements — Claude plans and judges, Codex plans/implements from a persistent thread, with approve-the-plan and review-the-diff gates. For delegating serious multi-file work to Codex instead of one-shot prompts.
---

# codex-claude-loop — the gated Claude × Codex build loop

Claude is the principal orchestrator; it rarely types product code. Codex CLI does the
hands-on implementation from **persistent threads**. The whole thing is bash around
`codex exec` — no framework, no MCP, no daemon.

## The cycle (one brief)

```
Claude writes a brief  →  Codex authors a plan (persistent thread)  →  back to Claude
   →  Claude APPROVES the plan (loop until tight)  →  Codex implements (same thread)
   →  Claude REVIEWS the diff vs the plan (loop until clean)  →  release
```

**The persistent thread is the trick:** the plan Codex authored carries into
implementation, so it implements *its own approved plan* with full context — not a
paraphrase relayed through a second cold prompt.

## Two lanes, pipelined, never idle

The orchestrator can run **two concurrent lanes** and pipeline "plan-on-plan":

- **Lane A — the work Claude does with its own hands** (taste-critical UI, judgment
  calls, anything where the *reason* to use Claude is Claude).
- **Lane B — the work Codex does**: Claude drives Codex through the cycle above.

**Pipeline rule (why it never idles):** *implementation is the only serialized step*
(one writer on the tree — `CL_LOCK` enforces it). Planning of brief N+1 and review of
brief N-1 are **read-only** and overlap implementation of brief N. So while Codex
implements N, Claude is already reviewing N-1's diff **and** approving N+1's plan → the
instant N lands, N+1 is ready to implement. Codex runs continuously; Claude is never
blocked.

```
impl(N)        [======= writes tree, lock held =======]
review(N-1)    [== read-only ==]
plan(N+1)              [== read-only ==]  approve(N+1) ✓  → impl(N+1) starts immediately
```

## How to run it

`source ${CLAUDE_PLUGIN_ROOT}/skills/codex-claude-loop/lib/codex-claude-loop.sh` then use the phase
functions, or call `bash lib/codex-claude-loop.sh <phase> …` directly. Config via env
(`CL_REPO`, `CL_IMPL_MODEL`, `CL_PLAN_MODEL`, `CL_REVIEW_MODEL`, `CL_SANDBOX`).

0. **First run:** `cl_doctor` (codex/jq/git present, repo + schema resolve).
1. **Codex plans:** `cl_plan <slug> <brief.md>` → writes `<slug>.plan.md`, opens a
   persistent thread, stores its session id.
2. **Claude approves the plan** (judgment — YOU read it): read `<slug>.plan.md`. If
   tight, `cl_record_verdict <slug> plan approve "why"`. If not, re-brief and re-plan.
   Loop until the plan holds. Prompt yourself to *refute* it, not rubber-stamp it.
3. **Codex implements:** `cl_impl <slug>` → resumes the thread, writes code, runs
   tests, holds the writer lock. Records the base SHA for review.
4. **Claude reviews the diff:** `cl_review_human <slug>` (rich review you read) — or
   inspect `git diff <base>` yourself. Judge it *against the plan*. Approve
   (`cl_record_verdict <slug> review approve`) or send the blocking items back into the
   same thread with `cl_revise <slug> "…"` and re-review. Loop until clean.
5. **Release:** changelog, tag, merge, deploy (honor the project's own deploy gate).

`cl_status` shows where every slug stands. `cl_wave <slug> <brief.md>` runs the safe
**sequential** version end-to-end (pauses at both gates). For the pipelined two-lane
run, call the phases directly and overlap the read-only ones across slugs.

## Autonomous fallback (no orchestrator to gate)

When there is no Claude brain available to judge (e.g. usage cap spent), `cl_codex_gate
<slug>` stands in a **Codex adversarial reviewer** that emits a parseable verdict
(`schemas/verdict.schema.json`, defaults to `revise` unless confident). Use it to keep
the loop moving unattended — but a real orchestrator review is the standard.

## Rails (load-bearing)

- **One writer.** Never run two `cl_impl` concurrently — `CL_LOCK` blocks it; don't
  bypass. Two Codex threads writing the same tree = corruption.
- **Gates must refute, not rubber-stamp.** A gate that always approves is worse than no
  gate. Plan/review prompts default to skepticism; blocking items need concrete fixes.
  `approve` with a non-empty blocking list is auto-downgraded to `revise`.
- **A new plan invalidates old verdicts.** `cl_plan` clears them; so does `cl_revise`.
  Never approve a diff against a plan that has since changed.
- **Verify model variants before architecting on them.** Set `CL_IMPL_MODEL` /
  `CL_REVIEW_MODEL` only to models you have actually confirmed behave as you assume.
- **Tail the log within a minute of launching any lane.** A bad flag makes `codex exec`
  die silently into its jsonl while you believe a lane is running.
- **First run = `cl_selfreview`:** have Codex adversarially tear apart THIS harness
  (bash bugs, locking, session-id capture, rubber-stamp holes) before you trust it.
- Honor the repo's own rules (branch protection, deploy gates, secrets never printed).

## State

`~/.codex-claude-loop/<repo>/` — plans, verdicts, session ids, base SHAs, JSONL logs. Outside
the repo so it never pollutes a tree Codex is writing. Override with `CL_STATE`.
