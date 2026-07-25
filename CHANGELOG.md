# Changelog

## 0.3.1 — 2026-07-25

**Gate 2 could be walked past with one git command.** A landscape scout found it and I
reproduced it against this repo: `git update-index --assume-unchanged <path>` makes the
index lie, so `git status` and `git diff HEAD` report nothing while the file is rewritten,
and `_cl_tree_id` returned a byte-identical digest. `cl_release` would then approve a tree
edited after its review. A `workspace-write` Codex can run that command.

Hashing every tracked file to route around the index costs a process per file, so instead
the tree id refuses when any path carries `assume-unchanged` or `skip-worktree`, and names
the paths. A check that cannot be trusted reports failure, never success.

- 58 → 60 assertions, including the reproduction itself

## 0.3.0 — 2026-07-25

**Intent drift.** A reader of the launch thread described the failure this loop did not
catch: Codex satisfies the wording of a blocking item, misses what the item was asking
for, and nobody notices until a later round. He asked whether the hash binding prevented
it. It did not. Hashing binds an approval to the state it judged; it says nothing about
whether a fix meant what the reviewer meant.

The gap was structural. `cl_revise` handed the blocking items to the Codex thread and kept
no copy, so the next review started from the diff alone and had no way to ask "did this
resolve what was asked?".

- `cl_revise` now appends each round's items to `<slug>.carryover.md`
- both review paths carry every earlier round into the prompt and are told to judge each
  item on intent: a change that satisfies the sentence and misses the point stays blocking,
  and the reviewer has to name the item, quote the line that satisfies the letter, and
  state the intent it misses
- reviewers also mark which items are settled, so later rounds stop re-litigating them
- `cl_plan` clears the carryover, since those items were raised against a plan that is gone
- 53 → 58 assertions

## 0.2.0 — 2026-07-25

Hardening pass after an adversarial review by Codex (`gpt-5.6-sol`, xhigh) of the 0.1.0
tree. Its verdict opened with "not release-ready: both hard gates can report approval for
state they did not validate, and the one-writer lock can admit two writers." Both were
true. Everything below closes a hole that existed in 0.1.0.

**Gates that actually gate**

- `cl_plan_approved` failed OPEN: a deleted `plan.md`, a missing digest, or a host with no
  sha256 tool all produced "no mismatch found", which read as approved. Every branch now
  fails closed, and the digest tool is `shasum`/`sha256sum`/`openssl` with a `cl_doctor`
  check.
- `cl_record_verdict` refuses to record an approval it could never verify later.
- Gate 2 had no consumer, so "two gates you cannot skip" was not true of the code. New
  `cl_release` refuses unless the review approved *this* tree, compared by base sha plus a
  hash of HEAD, every uncommitted change, and every untracked file's content.
- A failed autonomous gate used to leave the previous `approve` standing. The verdict is
  now cleared before each attempt, so a crash leaves the slug unapproved.
- `blocking` that is not an array made the length query fail, and the failure defaulted to
  zero blockers, which turned into an approval. The verdict shape is now validated
  independently of the schema and refused outright when it does not match.
- `cl_impl` and `cl_revise` clear the review approval before touching the tree; `cl_plan`
  also clears the recorded base and the success marker.
- New `<slug>.impl.ok` marker, written only when codex exits clean. Both review paths
  refuse without it, so a failed implementation can no longer be reviewed as if it worked.

**The lock**

- Two waiters that spotted the same dead pid could both `rm -rf` and both proceed.
  Reclamation now renames the lock, so only one waiter can win.
- Release verifies ownership: a process can no longer delete a lock another process holds.
- `INT`/`TERM` handlers release and then exit 130/143 instead of continuing to write.

**Update resistance that works**

- The `codex exec --help` memo assigned inside a command substitution, so it never
  memoized. It now populates in the calling shell.
- Capability probes test the exact spelling the driver invokes (`-o`), not an alternate
  one that would pass the probe and fail at the call site.
- The thread id must come from a documented thread-start event and must look like an id;
  a stray `session_id` on an error event can no longer become the thread we resume.

**Correctness elsewhere**

- State directory is keyed by a hash of the repo path, so `~/a/app` and `~/b/app` no
  longer share plans, threads and approvals.
- The implementation prompt now carries the approved plan text verbatim, so a plan a human
  edited and re-approved wins over what the thread originally drafted.
- Slugs are validated, so a slug cannot write outside the state directory; the lock must
  live inside it.
- `CL_WRITABLE_ROOTS`/`CL_NET` are declared, so `set -u` no longer silently dropped the
  flags; a whitespace path is rejected with an explanation instead of being split.
- `cl_wave` is a resumable state machine (rc 3 = your turn, rc 0 = both gates hold). It
  used to check for an approval it had just cleared, so it could only ever return 2.
- `cl_status` uses `find` instead of a glob, which aborted under zsh on an empty state.
- Dirty-baseline warning counts staged and untracked paths too.

**Installer**

- Transactional: stage beside the target, then swap, with rollback. A half-finished copy
  can no longer be the thing sitting at the install path.
- `--help` works through `curl | sh`, option arity is validated, and uninstall refuses any
  directory that does not carry this installer's marker.

**Tests**

- 33 → 53 assertions. The stub `codex` now enforces the invocation contract: it rejects a
  global flag placed after `resume`, requires `-C`/`-s`, and can assert which thread id it
  must be resumed with.
- Removed an assertion that had been proving the unsafe behavior (a failed gate leaving a
  stale approval readable).
- `gates.sh` reports RED when zsh, shellcheck or jq are missing, instead of green.

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
- Commands: `/codex-claude-loop:wave`, `/codex-claude-loop:status`, `/codex-claude-loop:doctor`
