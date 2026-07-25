# Changelog

## 0.1.0 — 2026-07-25

First public release. Extracted and generalized from a private build harness that had
already driven 45 gated waves across 20 lanes of a production codebase.

- `cl_plan` / `cl_impl` on one persistent Codex thread (the implementer authors the plan
  it later implements)
- Two judgment gates: `cl_gate_plan` + `cl_record_verdict`, `cl_review_human`
- `cl_codex_gate` — unattended adversarial reviewer constrained by `verdict.schema.json`
  (defaults to `revise`; `approve` with blocking items is downgraded)
- `mkdir`-based writer lock with stale-holder reclamation (macOS has no `flock`)
- Verdict invalidation on re-plan and on `cl_revise`
- New in extraction: `cl_doctor`, `cl_status`, `cl_revise`, `CL_LOCK_TIMEOUT`,
  repo-relative `CL_REPO`/`CL_STATE` defaults
- Commands: `/codex-loop:wave`, `/codex-loop:status`, `/codex-loop:doctor`
