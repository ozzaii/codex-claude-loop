---
description: Show every codex-loop slug and where it stands (plan/review verdicts, base SHA)
---

Load the `codex-loop` skill, source its lib, and run `cl_status`.

Then, for each slug that is not fully approved, say in one line what the next action is:
plan needs reading, plan needs re-briefing, impl not run, diff needs review, or blocking
items need `cl_revise`. If a slug has an approved review, say whether it has been
released (merged/tagged/deployed) or is still sitting.
