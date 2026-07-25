---
description: Run one gated Codex wave — plan, you approve, Codex implements, you review
argument-hint: <slug> <brief.md>
---

Run one full codex-claude-loop wave for `$ARGUMENTS`.

Load the `codex-claude-loop` skill and follow it exactly. Do not run `cl_wave` blindly — you
are the gate. Concretely:

1. `source ${CLAUDE_PLUGIN_ROOT}/skills/codex-claude-loop/lib/codex-claude-loop.sh` (and run
   `cl_doctor` if this is the first wave in this session).
2. If no brief file was given, write one first: goal, constraints, acceptance criteria,
   out-of-scope. A vague brief produces a vague plan and the loop can only be as good
   as its brief.
3. `cl_plan <slug> <brief>` → **read the plan yourself** and try to refute it. Record
   `cl_record_verdict <slug> plan approve|revise "<why>"`. If revise, re-brief and
   re-plan before going further.
4. `cl_impl <slug>` (writer lock is held for the duration — never launch a second one).
5. `cl_review_human <slug>` and read the real `git diff <base>` yourself. Judge it
   against the approved plan, not against your own idea of the task.
6. Blocking items → `cl_revise <slug> "<items>"`, then review again. Clean →
   `cl_record_verdict <slug> review approve "<why>"`.

Report at the end: what landed, what you rejected and why, and what is still open.
