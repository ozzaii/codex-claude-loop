# codex-claude-loop

A gated build loop between Claude Code and Codex CLI. Codex writes the plan, Claude
approves it, Codex implements **that same plan from the same thread**, Claude reviews the
diff against it.

```
brief → codex plans → CLAUDE APPROVES → codex implements → CLAUDE REVIEWS → release
                          ▲ gate 1                              ▲ gate 2
```

Bash around `codex exec`. No MCP server, no daemon, no Python.

## Install

**In Claude Code** (recommended, updates handled for you):

```
/plugin marketplace add ozzaii/codex-claude-loop
/plugin install codex-claude-loop@codex-claude-loop
```

**Anywhere else** (installs the skill into `~/.claude/skills/`):

```bash
curl -fsSL https://raw.githubusercontent.com/ozzaii/codex-claude-loop/main/install.sh | sh
```

The installer runs `doctor` when it finishes, so you learn straight away whether your
Codex can drive the loop. Flags: `--dir <path>`, `--ref <tag>`, `--uninstall`.

You need [Codex CLI](https://developers.openai.com/codex/cli) (`npm i -g @openai/codex`
then `codex login`), plus `jq` and `git`.

## Use

In Claude Code: `/codex-claude-loop:wave <slug> <brief.md>` walks the whole cycle and
stops at both gates for your judgment. `/codex-claude-loop:status` shows where every slug
stands. `/codex-claude-loop:doctor` checks the substrate.

From a shell:

```bash
source ~/.claude/skills/codex-claude-loop/lib/codex-claude-loop.sh

cl_doctor
cl_plan  auth-rl briefs/auth-rl.md         # codex writes the plan, thread stays open
#   read the plan. Try to refute it. Then:
cl_record_verdict auth-rl plan approve "contracts and migration order hold"
cl_impl  auth-rl                           # same thread implements it, holds the lock
cl_review_human auth-rl                    # adversarial review of the diff vs the plan
cl_revise auth-rl "1) bucket resets on deploy, persist it  2) …"
cl_record_verdict auth-rl review approve "blockers cleared, tests green"
cl_status
```

Unattended, with nobody to judge: `cl_codex_gate <slug>` runs a Codex reviewer bound to
[`verdict.schema.json`](plugin/skills/codex-claude-loop/schemas/verdict.schema.json). It
defaults to `revise`, and an `approve` carrying blocking items gets downgraded on disk.

## Why the same thread

Most Claude + Codex setups paste a plan into a fresh Codex prompt, so Codex implements a
summary of reasoning it never did. Here `cl_plan` opens a persistent thread, has Codex
author the plan **as the implementer**, and stores the thread id. `cl_impl` resumes that
exact thread. The review gate judges the diff against the stored plan file, so "it built
something else, but nice" is a blocking finding rather than a shrug.

## Two lanes, pipelined

Implementation is the only serialized step, guarded by a `mkdir` lock. Planning the next
brief and reviewing the previous diff are read-only, so they overlap it:

```
impl(N)        [======= writes tree, lock held =======]
review(N-1)    [== read-only ==]
plan(N+1)              [== read-only ==]  approve ✓ → impl(N+1) starts immediately
```

Codex never idles, and Claude keeps its own lane for the work that is the reason to use
Claude.

## What it refuses to do

A gate that always approves is worse than no gate.

- `cl_impl` refuses unless the plan verdict is `approve`
- `cl_impl` refuses without a stored thread id, and never falls back to `resume --last`
- a fresh `cl_plan` deletes both verdicts, `cl_revise` deletes the review verdict
- a failed autonomous gate returns rc 2 and leaves no stale verdict behind
- `approve` plus a non-empty `blocking[]` becomes `revise`, rewritten in the file
- a second `cl_impl` waits on the lock; a lock orphaned by Ctrl-C is reclaimed by pid

## Surviving a Codex update

The CLI moves, and a moved flag used to mean a lane that died silently into its log.

- `cl_doctor` probes the four things the loop depends on (`exec`, `--json`, `-o`,
  `exec resume`) and accepts alternate spellings, so a rename is not read as a loss
- the thread id is parsed in three tiers: the known event shape, then drifted keys and
  event names, then any id-carrying line. Tiers 2 and 3 announce themselves in the log
- a codex family outside the tested set prints one warning, then continues
- `cl_impl` refuses when `exec resume` is gone, `cl_codex_gate` refuses when
  `--output-schema` is gone, and both say what to do instead

## Config

| Env | Default | Notes |
|---|---|---|
| `CL_REPO` | git root of `$PWD` | the tree Codex writes |
| `CL_STATE` | `~/.codex-claude-loop/<repo>` | plans, verdicts, thread ids, logs, kept outside the repo |
| `CL_SANDBOX` | `workspace-write` | implementation sandbox |
| `CL_PLAN_SANDBOX`, `CL_REVIEW_SANDBOX` | `read-only` | raise only on hosts where sandboxing itself fails |
| `CL_IMPL_MODEL`, `CL_PLAN_MODEL`, `CL_REVIEW_MODEL` | codex default | plan cheap, review strong |
| `CL_WRITABLE_ROOTS` | | needed when `CL_REPO` is a linked worktree |
| `CL_NET` | | `1` grants the sandbox network for test gates |
| `CL_LOCK_TIMEOUT` | `7200` | seconds to wait for the writer lock |

## Field notes

Each of these cost hours before it became a line of code.

- `codex exec resume <id>` rejects global flags placed after `resume`. `-C/-s/-o` go
  before it, or the lane dies silently in its log. Tail every lane within a minute.
- `codex review --base <sha> "<prompt>"` is invalid, `--base` cannot combine with a
  prompt. The reviewer runs `git diff` itself instead.
- The `--json` stream carries non-JSON stderr, and `jq` aborts at the first bad line.
  Filter `grep -a '^{'` before parsing.
- `zsh` expands a whole `local a="$1" b="${a}x"` line before assigning, so `b` is empty.
- Linked worktrees need `CL_WRITABLE_ROOTS`, or commits fail with `cannot lock ref`.
- Some hosts cannot run a sandboxed shell at all, which is what the per-phase sandbox
  variables are for.
- `cmd | grep -q pattern` under `set -o pipefail` reports failure when the match arrives
  early: `grep -q` closes the pipe and the producer takes SIGPIPE. Capture first, match
  second.
- An implementation of only new files looks like an empty diff, so the gate prompt forces
  `git status --short` too.

Run `cl_selfreview` on day one: Codex tearing this harness apart before you trust it.

## Tests

```bash
./gates.sh             # smoke (bash + zsh) + shellcheck + manifest validation
bash test/smoke.sh     # 27 assertions, no Codex quota spent
```

The suite drives the whole loop against a stub `codex` and asserts that the gates gate:
implementation refuses an unapproved plan, an `approve` with blockers is downgraded on
disk, a re-plan clears both verdicts, a dead lock holder is reclaimed while a live one
blocks, a drifted thread event still parses, and a removed flag produces a refusal rather
than a silent death.

## Prior art

| | What it is | Use it when |
|---|---|---|
| [openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc) | Official plugin: `/codex:review`, `/codex:rescue`, background jobs | You want the primitives. It composes with this |
| [skills-directory/skill-codex](https://github.com/skills-directory/skill-codex) | A skill that forwards a prompt to Codex | One-shot delegation, no gates |
| [alexzh3/codex-orchestrator](https://github.com/alexzh3/codex-orchestrator) | Run artifacts, journals, reports (Python 3.10+) | You want reporting and don't mind Python |
| [iselur/relay](https://github.com/iselur/relay) | Autonomous backlog and cross-vendor review on a shared VM | You want unattended autonomy and will run infrastructure |
| **codex-claude-loop** | The loop discipline itself: two gates, one thread, one writer lock, schema-checked verdicts | You want it auditable in one file, with Claude actually gating |

## Provenance

Extracted from the harness behind [BRAVOH](https://beta.bravoh.ai), where it ran 45 gated
waves across 20 lanes of a production TypeScript and React Native codebase. Every field
note above comes from that run.

MIT.
