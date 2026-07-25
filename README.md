# codex-loop

**A gated build loop between Claude Code and Codex CLI.** Codex authors a plan, Claude
approves it, Codex implements *that same plan from the same thread*, Claude reviews the
diff against it. Two hard gates, one writer lock, ~330 lines of bash. No MCP server, no
daemon, no Python.

```
Claude writes a brief  →  Codex authors a plan (persistent thread)  →  back to Claude
   →  Claude APPROVES the plan (loop until tight)  →  Codex implements (same thread)
   →  Claude REVIEWS the diff vs the plan (loop until clean)  →  release
```

## Why the thread matters

Most Claude↔Codex setups relay a plan by pasting it into a fresh Codex prompt. Codex
then implements a *summary* of a plan it never reasoned about.

Here, `cl_plan` opens a persistent Codex thread, has Codex author the plan **as the
implementer**, and stores the thread id. `cl_impl` resumes that exact thread. Codex
implements its own approved plan with the whole reasoning chain still in context. The
review gate then judges the diff *against that plan file*, so "it built something else,
but nice" is a blocking finding rather than a shrug.

## Install

```bash
/plugin marketplace add ozzaii/codex-loop
/plugin install codex-loop@codex-loop
```

Requires [Codex CLI](https://developers.openai.com/codex/cli) ≥ 0.144 (`npm install -g
@openai/codex && codex login`), plus `jq` and `git`. Then, in Claude Code:

```
/codex-loop:doctor          # verify the substrate
/codex-loop:wave auth-rl briefs/auth-rate-limit.md
/codex-loop:status
```

Not on Claude Code? The harness is a plain script — `bash
plugin/skills/codex-loop/lib/codex-loop.sh doctor` works from any shell.

## The loop, by hand

```bash
source plugin/skills/codex-loop/lib/codex-loop.sh

cl_doctor                                  # codex/jq/git, repo, schema
cl_plan  auth-rl briefs/auth-rl.md         # → auth-rl.plan.md + a persistent thread
#   ...read the plan. Try to refute it. Then:
cl_record_verdict auth-rl plan approve "contracts + migration order are right"
cl_impl  auth-rl                           # resumes the thread, writes code, holds the lock
cl_review_human auth-rl                    # adversarial review of the diff vs the plan
cl_revise auth-rl "1) token bucket resets on deploy — persist in redis  2) …"
cl_record_verdict auth-rl review approve "blockers cleared, tests green"
cl_status
```

Fully unattended (no human/Claude to judge): `cl_codex_gate <slug>` runs a Codex
adversarial reviewer constrained by [`verdict.schema.json`](plugin/skills/codex-loop/schemas/verdict.schema.json)
— it emits `{verdict, summary, blocking[], plan_deviations[], nits[]}`, defaults to
`revise` unless confident, and an `approve` carrying blocking items is auto-downgraded.

## Pipelined: two lanes, never idle

Implementation is the **only** serialized step — one writer on the tree, enforced by a
`mkdir` lock (macOS has no `flock`). Planning the next brief and reviewing the previous
diff are read-only, so they overlap:

```
impl(N)        [======= writes tree, lock held =======]
review(N-1)    [== read-only ==]
plan(N+1)              [== read-only ==]  approve(N+1) ✓ → impl(N+1) starts immediately
```

Codex runs continuously; Claude is never blocked waiting on it. Meanwhile Claude keeps
its own lane for the work that is the *reason* to use Claude — taste-critical UI,
architecture, judgment.

## What it refuses to do

A gate that always approves is worse than no gate, so:

- `cl_impl` **refuses** to run if the plan verdict isn't `approve`.
- `cl_impl` **refuses** to run without a stored thread id (never `resume --last` — a
  newer thread from another lane may be the "last" one).
- A fresh `cl_plan` **deletes** both prior verdicts; `cl_revise` deletes the review
  verdict. You can never approve a diff against a plan that has since moved.
- A failed autonomous gate returns rc 2 and **does not** leave a stale verdict behind.
- `approve` + non-empty `blocking[]` → downgraded to `revise`.
- Two concurrent `cl_impl` calls → the second waits on the lock (stale holders are
  reclaimed by pid).

## Configuration

| Env | Default | Notes |
|---|---|---|
| `CL_REPO` | git root of `$PWD` | the tree Codex writes |
| `CL_STATE` | `~/.codex-loop/<repo>` | plans, verdicts, thread ids, logs — kept **outside** the repo |
| `CL_SANDBOX` | `workspace-write` | implementation sandbox |
| `CL_PLAN_SANDBOX` / `CL_REVIEW_SANDBOX` | `read-only` | raise only on hosts where sandboxing itself fails |
| `CL_IMPL_MODEL` / `CL_PLAN_MODEL` / `CL_REVIEW_MODEL` | codex default | e.g. a cheaper model to plan, a stronger one to review |
| `CL_WRITABLE_ROOTS` | — | needed when `CL_REPO` is a **linked worktree** (git writes objects into the parent `.git`) |
| `CL_NET` | — | `1` grants the sandbox network (npm, a DB on loopback) for test gates |
| `CL_LOCK_TIMEOUT` | `7200` | seconds to wait for the writer lock |

## Field notes (why the code looks like it does)

Each of these cost real hours before it became a line of code:

- `codex exec resume <id>` rejects global flags placed **after** `resume`. `-C/-s/-o`
  must come before it — otherwise the lane dies silently into its log and you find out
  hours later. Tail every lane's log within a minute of launching it.
- `codex review --base <sha> "<prompt>"` is invalid — `--base` can't combine with a
  prompt. The reviewer runs `git diff` itself instead.
- The `--json` stream interleaves non-JSON stderr (ANSI error spam); `jq` aborts at the
  first bad line. Filter `grep -a '^{'` before parsing, and parse **only**
  `thread.started` for the thread id.
- `zsh` expands an entire `local a="$1" b="${a}x"` line before assigning, so the second
  variable is empty. Two `local` statements, or your logs land in a slugless file.
- Linked worktrees need `CL_WRITABLE_ROOTS` pointing at the parent repo, or commits fail
  with `cannot lock ref`.
- Some hosts can't run a sandboxed shell at all (bwrap failing on loopback inside a VM,
  symlinks escaping the allowed roots). That's what the per-phase sandbox vars are for.
- An implementation of only *new* files looks like an empty diff to a lazy reviewer —
  the gate prompt forces `git status --short` too.

Run `cl_selfreview` on day one: Codex adversarially tearing apart this harness before
you trust it with your tree.

## Tests

```bash
bash test/smoke.sh     # 20 assertions, no Codex quota spent
zsh  test/smoke.sh     # same assertions under zsh (the harness is sourced from both)
```

The suite drives the entire loop against a stub `codex` and asserts the gates actually
gate: implementation refuses an unapproved plan, the tree stays untouched before
approval, a thread id survives ANSI noise in the JSON stream, an `approve` carrying
blockers is downgraded **on disk**, a failed gate leaves no stale verdict, a re-plan
clears both verdicts, a dead lock holder is reclaimed while a live one blocks, and the
harness never steals the calling shell's `EXIT` trap.

## Prior art (read this before choosing)

This space is crowded. Honest positioning:

| | What it is | Use it when |
|---|---|---|
| [openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc) | Official OpenAI plugin: `/codex:review`, `/codex:rescue`, background jobs | You want the primitives — delegate a task, get a review. **Composes fine with this**; codex-loop is the discipline you put on top |
| [skills-directory/skill-codex](https://github.com/skills-directory/skill-codex) | A skill that forwards a prompt to Codex | One-shot delegation, no gates |
| [alexzh3/codex-orchestrator](https://github.com/alexzh3/codex-orchestrator) | Run-based orchestration with reports, journals, benchmarks (Python 3.10+) | You want run artifacts and reporting, and don't mind the Python dependency |
| [iselur/relay](https://github.com/iselur/relay) | Autonomous backlog + cross-vendor review on a shared VM (tmux, Tailscale, sandboxed users) | You want unattended autonomy and will run infrastructure for it |
| **codex-loop** | Two judgment gates, one persistent implementer thread, a writer lock, schema-checked verdicts — in bash, zero deps beyond `codex`/`jq`/`git` | You want the *loop discipline* itself, auditable in one file, and you want Claude to actually gate rather than rubber-stamp |

## Provenance

Extracted from the build system behind [BRAVOH](https://beta.bravoh.ai). Before
extraction it drove **45 gated waves across 20 lanes** (repos and linked worktrees) of a
production TypeScript/React Native codebase — every field note above comes from that
run, not from a demo.

MIT.
