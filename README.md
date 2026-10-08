# agent-loop

Two headless, unattended agent modes for working a GitHub issue backlog, both
on the backend of your choice:

- **`run-issue.sh`** — implements an issue in its own git worktree and gets
  back a pushed branch (never a merge, never an opened PR, never a closed
  issue) for human review.
- **`refine-issue.sh`** — turns a rough issue into a consistently
  well-specified one (or, when it genuinely needs a product/design decision
  it can't make itself, into a clear list of exactly what's unresolved). Its
  only side effect is `gh issue edit`; it never touches code, branches, or
  tests, and a safety check after every run confirms its worktree came back
  clean.

Two companion scripts turn "pushed branches" into "things to review":

- **`status.sh`** — lists every issue seen in the log directory, with its
  branch, whether it's pushed, its PR state, and whether it's merged.
- **`open-pr.sh`** — idempotently ensures a PR exists for a completed
  issue's branch: creates one (assigned to the repo owner) if missing,
  prints the existing URL otherwise. `run-issue.sh` still never opens a PR
  itself; this is the explicit, human-invoked step that does, so review
  always ends up going through one regardless of backend.

Grew out of orchestrating a Claude Code session that spins up other agent
CLIs to work through a project's issue backlog: Claude watches the log,
decides what's next, and launches the next issue when one finishes. This repo
is the reusable part of that: the launcher script and per-project config, not
the orchestration loop itself (which lives in whatever session is driving it).

## Supported backends

- `codex` — [OpenAI Codex CLI](https://github.com/openai/codex), via `codex exec --approve-for-me`
- `cursor` — [Cursor Agent CLI](https://cursor.com/cli), via `cursor-agent -p --force`
- `claude` — [Claude Code](https://claude.com/claude-code), via `claude -p --permission-mode auto`

Each backend still runs under whatever guardrails its own CLI provides in
that mode (Codex's workspace-write sandbox + auto-review, Cursor's allowlist
mode, Claude's auto-mode classifier) — this tool does not bypass those, it
just drives them non-interactively.

## Platforms

Pure POSIX bash. Tested on Windows via Git Bash (MINGW), and written to work
unmodified on macOS and Linux. The one platform-specific behavior is Cursor's
`--sandbox` flag, which the script only passes on macOS/Linux (Cursor's
sandbox mode isn't available on Windows; Windows falls back to its allowlist
mode via `--force` alone).

## Prerequisites

- `git`, `gh` (authenticated for the target repo), `jq`. `run-issue.sh` and
  `refine-issue.sh` fall back to `python3`/`python` if `jq` isn't on PATH;
  `status.sh`, `open-pr.sh` and `report.sh` (unless `--no-refresh`) require `jq`
- `python3` (or `python`) for tiers, pool routing, state files, `report.sh` and
  `pool-status.sh`; a missing tool exits **96**
- Whichever backend CLI(s) you plan to use, authenticated and on PATH

## Usage

```sh
bash run-issue.sh --project <name> --issue <N> --backend <codex|cursor|claude> \
     [--effort <low|medium|high|xhigh|max>] [--model <id>] \
     [--timeout <minutes>] [--stall <minutes>]
bash refine-issue.sh --project <name> --issue <N> --backend <codex|cursor|claude> \
     [--effort <low|medium|high|xhigh|max>] [--model <id>]
bash status.sh --project <name>
bash open-pr.sh --project <name> --issue <N>
bash backfill-sessions.sh --project <name> [--dry-run]
bash pool-status.sh --project <name>
bash report.sh --project <name> [--no-refresh]
bash verify-backends.sh [--project <name>] [--backend <codex|cursor|claude>]...
```

`--effort` picks the reasoning level per backend (claude `--effort`, codex
`model_reasoning_effort`, cursor a Grok 4.6 tier); `--model` overrides it with
an explicit id. Both also read `AGENT_EFFORT` / `AGENT_MODEL` from the
environment, which the flags take precedence over. `--timeout` / `--stall`
(minutes; `AGENT_TIMEOUT_MIN` / `AGENT_STALL_MIN`) tune the [watchdog](#watchdog)
on `run-issue.sh` and `run-pr.sh`; `--auto-escalate` (`AGENT_AUTO_ESCALATE=1`)
opts into automatic [tier escalation](#dead-end-ledger-and-tier-escalation).

### Task tiers

`--tier` says what the work *needs* rather than where it runs, and resolves to
the cheapest route clearing that bar whose pool can still afford a session:

| tier | for | resolves to today |
|------|-----|-------------------|
| `mechanical` | dep bumps, lint, docs, test writing, small refactors | `grok-low` |
| `standard` | a well-specified issue | `grok-medium` |
| `frontier` | ambiguous or cross-cutting work, or a repeat failure | `sol-medium`, or `opus-medium` once Codex is spent |

```sh
bash run-issue.sh --project myproject --issue 110 --tier mechanical
```

**Claude is the last-resort worker.** `mechanical` and `standard` each carry a Claude Sonnet 5 route
that sorts after every calibrated route, so it is chosen only once Cursor and Codex cannot afford a
session. Leaving Claude idle to protect the orchestrator would stall the queue, so `claude-pro` holds a
smaller `reserve_pct` instead. Those two rates are estimates until real Claude sessions have run;
`sessions.jsonl` records their exact usage.

**Nothing given explicitly is overridden** — the tier fills only what you left
open, so `--tier mechanical --backend codex` still runs codex. A tier whose
routes are all spent exits 90 rather than widening the search: the tier is the
quality bar the work needs, so the answer to "nothing affordable clears it" is
to wait for a reset, not to send the work somewhere that can't do it.

The tier is recorded in `sessions.jsonl`, so `report.sh` can later compare what
a tier was expected to cost against what it actually cost, and whether the
cheap tier produced work that needed rework. **No existing default changed:**
runs without `--tier` behave exactly as before. Flipping defaults is a decision
for after that comparison, not before it.

Both print the log file path immediately, then run the whole session
(worktree setup, issue fetch, prompt build, backend invocation) appending to
that log. The last line of a completed run is always:

```
___ISSUE_<N>_<backend>_EXIT_<code>___              # run-issue.sh
___ISSUE_<N>_<backend>_REFINE_EXIT_<code>___        # refine-issue.sh
```

and, from the agent's own final message, a result line:

```
ISSUE_<N>_RESULT: <PUSHED|BLOCKED|FAILED> branch=<branch-name-or-none> tests=<short-summary>
ISSUE_<N>_REFINE_RESULT: <READY|NEEDS_REFINEMENT|FAILED> summary=<short-summary>
```

Watch for both — the exit sentinel confirms the process actually finished;
the result line is the agent's self-report of what it did. An orchestrating
session typically tails the log for these plus real failure signatures
(`rate.?limit exceeded`, `quota exceeded`, `^fatal:`, `REFINE_SAFETY_VIOLATION`,
timestamped `ERROR` lines) rather than polling.

`refine-issue.sh` uses its own disposable worktree
(`<repo>-issue-<N>-refine`, separate from the build worktree so both can be
in flight) and removes it automatically after a clean run. If the refine
session somehow left file changes behind, the script leaves the worktree in
place and logs `REFINE_SAFETY_VIOLATION` instead of silently discarding or
committing anything — that should never happen given the prompt, so treat it
as a bug report if it does.

## Scope, setup and warnings

This is a personal tool shared as-is: no support is promised, and it tracks
fast-moving CLIs (`claude`, `codex`, `cursor-agent`) whose flags and behavior
change, so expect to adjust things.

- **Platform.** Built and used on Windows with Git Bash; the scripts are POSIX
  bash and are meant to work on macOS and Linux too, but that path is less
  exercised.
- **Prerequisites.** `git`, `gh` (authenticated), `python3` (or `python`), `jq`,
  and whichever backend CLIs you use, each already logged in.
- **Setup.** Copy `projects/example.env` to `projects/<name>.env` and
  `pools.example.yaml` to `pools.yaml`, then edit both. Both real files are
  gitignored. Every number in the example pools is a placeholder; calibrate it
  against your own usage dashboards.
- **This runs coding agents unattended with broad permissions**, in git
  worktrees, and pushes branches. Read what a session is told to do (below)
  and try it on a throwaway repo first.

## Project config

Each target repo gets a `projects/<name>.env` file. Copy `projects/example.env` to start; real `projects/*.env` files are gitignored so local paths never get committed:

```sh
REPO_PATH="/path/to/local/checkout"
REPO_SLUG="owner/repo"
DEFAULT_BRANCH="main"          # optional, defaults to main
WORKTREE_BASE="/path/to/put/worktrees"   # optional, defaults to the repo's parent dir
LOG_DIR="/path/to/logs"        # optional, defaults to ./logs
STATUS_FILE=""                 # optional: a living status doc to tell the agent to append to
STANDING_RULES_FILE=""         # optional: extra project-specific rules to inline into every prompt
CURSOR_RULES_EXTRA_FILE=""      # optional: extra rules appended to the .cursor/rules file installed for cursor runs
MAX_CONCURRENT=3               # optional: launches allowed in flight at once (0 disables the gate)
LAUNCH_STAGGER=40              # optional: seconds to space launches on the same backend
```

**Cursor standing rules.** Cursor has no hooks, so for `cursor` runs the launcher writes `lib/cursor-rules.mdc` (read narrowly, cap output, stay in scope, finish and stop) to `.cursor/rules/agent-loop.mdc` in the worktree, where `cursor-agent` loads it as an always-on rule. It is added to the repo's `info/exclude` so it never reaches a branch, PR, `git status` or the worktree-clean check, and it is removed when the session ends (a killed session can leave it behind, harmlessly). Other backends never get it. Rules are advisory; measure with `report.sh` rather than assuming.

`AGENT_MAX_CONCURRENT` / `AGENT_LAUNCH_STAGGER` override those two for a single
run without editing the file.

Worktrees are always named `<repo-name>-issue-<N>` under `WORKTREE_BASE`, so
multiple projects can share a worktree base without colliding.

## What every `run-issue.sh` session is told to do

Baked into every prompt, regardless of backend:

- Work only inside its assigned worktree; create its own `feat/<N>-slug` or
  `fix/<N>-slug` branch there.
- Re-check the live issue state itself (the prompt is a snapshot).
- Commit after every discrete step, not just at the end.
- Run the full test suite before calling anything done.
- Push the branch when finished or when stopping at a clean checkpoint.
  **Never open a PR, merge, or close the issue** — that's a human step.
- Stop cleanly around 95% of its own usage rather than push for a reset.
- Never touch its own provider's account/usage UI via computer-use.
- Stop immediately, without starting work, if the issue turns out to be
  blocked on an unmerged prerequisite.
- End with the `ISSUE_<N>_RESULT` sentinel line.

## Disposable single-task sessions (`--task-file`, `--chain`)

The whole-issue mode above hands a session an entire issue and lets it decide
when it's done; a long-lived session is where context drift, compaction and
retried dead ends come from. `run-issue.sh --task-file <path>` runs the
opposite shape: exactly **one scoped step**, driven by a task file that is the
session's *entire* instruction (not a supplement to the issue body -- a
replacement for it), and then the process exits. `--chain` runs every step
for an item in order, stopping at the first one that doesn't make progress.

**Task file template** (`<LOG_DIR>/tasks/<project>-<issue>-<step>.md`, `##`
headers, any order, validated by `lib/taskfile.py`):

```markdown
## Goal
One sentence, one deliverable.

## Files in scope
- path/one
- path/two

## Done when
A checkable exit condition (a test passes, a file has X).

## Do not
Optional: what adjacent steps own.

## Context
Optional: only what this step needs.
```

`Goal`, `Files in scope` and `Done when` are required and must be non-empty;
`taskfile_check` (`lib/taskfile.sh`) rejects a file missing any of them before
a session ever starts, no pool spent. `Do not` and `Context` are optional.

```sh
bash run-issue.sh --project myproject --issue 42 --task-file logs/tasks/myproject-42-01.md --backend codex
bash run-issue.sh --project myproject --issue 42 --chain --backend codex
```

- **The worktree and branch are reused across steps.** `setup_worktree`
  already creates once and reuses after; the first step's prompt tells it to
  create a branch, every later step's prompt tells it to stay on the one
  that's already there. Progress lives in commits, never in a carried-over
  transcript.
- **`--chain` finds its steps itself**: every
  `<LOG_DIR>/tasks/<project>-<issue>-*.md`, ordered by the numeric `<step>`
  in the filename (`01`, `02`, ... sort numerically, not lexicographically).
- **The launcher verifies progress, not just exit code.** It compares the
  worktree's `HEAD` before and after each step; if it didn't move, that's
  logged as `NO_PROGRESS: issue #<N> step <s> made no new commit` regardless
  of what the agent's own result line claimed, and `--chain` stops there,
  leaving the worktree in place for the orchestrator.
- **Each step is its own row in `sessions.jsonl`** (`kind: "task"`, `item`
  the issue, `round` the step number), and gets the same
  [watchdog](#watchdog) and [state file](#per-item-state-file-log_dirstate)
  treatment as a whole-issue session.
- Ends with `TASK_<N>_<step>_RESULT: <PUSHED|FAILED> branch=... tests=...`
  instead of the whole-issue `ISSUE_<N>_RESULT` line.

Auto-decomposing an issue into task files is not built here -- the issue's own
open question recommended starting with hand-written or planner-written task
files and comparing retry rates via `report.sh` before automating that step.

## What every `refine-issue.sh` session is told to do

- Its worktree is for reading only — no branch, no file edits, no commits,
  no tests. Its only mutating action is `gh issue edit`.
- Check live issue **and dependency** state itself rather than trust the
  snapshot, and ground the rewrite in what's actually in the repo (real
  paths, real conventions) rather than inventing scope.
- Decide against a specific bar: ready means an unattended coding session
  could implement it with *zero further product/design decisions* — not
  "clear enough for a person to muddle through."
- If it's ready: rewrite the body into a consistent spec (outcome, scope
  boundaries, dated decisions, real dependencies by issue number, an
  acceptance-criteria checklist), label `ready`, unlabel `needs-refinement`.
- If it's not: never guess at the missing product/business decision itself.
  Rewrite the body to enumerate exactly what's unresolved and what input
  each open point needs, label `needs-refinement`, unlabel `ready`.
- End with the `ISSUE_<N>_REFINE_RESULT` sentinel line.

## PR work items and the review-round cap (`run-pr.sh`)

`run-pr.sh --project <name> --pr <N> --task <fix-findings|merge-main|fix-ci|custom>`
launches one session on an existing PR branch (it finds the worktree that already has
the branch, fast-forwards it, merges `origin/<base>` and pushes the same branch;
never rebases, force-pushes, merges the PR or comments). `--effort low|medium|high|xhigh|max`
sets reasoning effort per backend (claude `--effort`, codex `model_reasoning_effort`,
cursor Grok 4.6 tier); `--model` overrides. Logs end with `___PR_<N>_<backend>_EXIT_<rc>___`
and a `PR_<N>_RESULT:` line.

**Review-round cap.** A *round* is one completed `fix-findings` run (one that printed a real
`PR_<N>_RESULT:` line; failed or interrupted launches do not count). Automated re-reviews tend
to surface one more edge case each time, and a session that keeps patching accumulates
context and drifts. So after **3 rounds** (`--max-rounds N` or `AGENT_MAX_REVIEW_ROUNDS`)
`run-pr.sh` will not start a fourth in the same context:

1. It writes `<LOG_DIR>/pr-state/<project>-pr-<N>-handoff.md`: the PR state, every prior
   round's log and result line, the newest review comments, and guidance. It links to the
   item's [state file](#per-item-state-file-log_dirstate) rather than repeating it; the
   goal, facts, dead ends and next step reach the new session from there.
2. It prints `REVIEW_ROUND_CAP: ...` and exits **91** without starting an agent.
3. The orchestrator then chooses: either start a fresh session with
   `run-pr.sh ... --task fix-findings --new-session [--effort high|xhigh]` (this resets the
   counter via `<LOG_DIR>/pr-state/<project>-pr-<N>.reset` and injects the brief, so the new
   session fixes the *class* behind the findings instead of the newest instance), or, if only
   small edge cases remain (no crash, data loss or security), recommend merging and track the
   rest as a follow-up issue. `merge-main`, `fix-ci` and `custom` runs are not rounds.

## Per-session accounting (`sessions.jsonl`)

Every run appends one JSON object to `<LOG_DIR>/sessions.jsonl`, so "what did
this PR cost, on which pool, and did it merge" is answerable from data rather
than estimated from wall-clock. Recording is free: it reads artifacts the run
already produced and adds no model turns.

```json
{"ts_start":1789830558,"ts_end":1789831819,"duration_s":1261,
 "project":"myproject","kind":"pr-merge-main","item":"94","round":null,
 "backend":"codex","model":"default","effort":"high","pool":"chatgpt-pro",
 "turns":51,"tokens":261857,"cost_usd":null,"state_seeded":true,"state":"valid",
 "termination":"completed","retried_dead_ends":1,"compactions":null,
 "tool_output_chars":2976602,"tool_output_max_chars":153211,
 "result":"PUSHED","exit_code":0,"log":"myproject-pr-94-...-codex-pr-merge-main.log"}
```

What each backend can actually report differs, and the log says so rather than
filling gaps with zeros — **a null means unknown, never none**:

| backend | tokens | cost | turns |
|---------|--------|------|-------|
| `codex` | its own `tokens used` line | — | tool-call markers in the log |
| `claude` | `.usage` from `--output-format json` | `.total_cost_usd` | `.num_turns` |
| `cursor` | not reported at any output format | — | not marked in text output |

So a cursor session's cost is inferred from `duration_s` and `result` until
Cursor's CLI exposes usage. `pool` is derived from the resolved model; an
unpinned cursor run records `cursor-auto`, because the model is chosen
server-side and nothing local records which one it was.

Two side effects of the capture, both useful on their own:

- `claude` runs go through `--output-format json` and the readable result is
  printed to the log afterwards, so the log format is unchanged.
- `codex` runs also write their final message to `<log>.usage.json.last` via
  `-o`, so the result sentinel can be read from a two-line file instead of
  grepping a multi-megabyte log.

### Session-quality fields

Cost says what a session used; these say how it went, so a change (the state
file, the watchdog, a cheaper tier) can be judged against a baseline. They are
additive: records written before them still parse, and read as unknown.

| field | meaning | source |
|-------|---------|--------|
| `termination` | `completed` (clean exit), `failed` (non-zero or missing exit), `pool-refused` (launcher declined to start; nothing ran), `watchdog` (the [watchdog](#watchdog) killed it) | exit code; `pool-refused` and `watchdog` are written by the launchers directly |
| `retried_dead_ends` | calls identical to one that already failed, with no file edit in between | codex: the log's `exec` blocks; claude: its session transcript; cursor: its local chat store |
| `compactions` | times the session's context was compacted | claude only: `compact_boundary` entries in its transcript (codex and cursor do not expose it) |
| `tool_output_chars` | total characters of tool output | codex log / claude transcript / cursor chat store |
| `tool_output_max_chars` | the largest single tool output | same; the "8,000-14,000 line search" problem, measured |
| `state_seeded`, `state` | see the state file section | launcher |

**Unknown is `null`, never `0`.** A backend that cannot report a field leaves it
null, and `report.sh` leaves those sessions out of every average and says how many
it could measure. Cursor's CLI prints only its final message, so nothing in the log
says what its tools did; the numbers come instead from the chat store cursor-agent
keeps per session, `~/.cursor/chats/<md5 of the worktree path>/<chatId>/store.db`
(SQLite; opened read-only, and the chat is the one created since the session
started). It records every tool call and its result, so cursor gets
`retried_dead_ends`, `tool_output_chars` and `tool_output_max_chars`; a result
counts as failed on an `Error`/`Rejected` prefix or a non-zero `Exit code:`. If no
chat is found (another machine, a moved `~/.cursor`) they stay null. A shell output
too large for the tool is written to a file and the result only names it, so cursor's
volume is a floor. `compactions` stays null for cursor. `retried_dead_ends` counts an
identical re-run only when nothing was edited in between (re-running a failing test
after a fix is the normal loop, not a dead end); an edit made through a shell command
is invisible, so that count can run high, and a retry with changed arguments is
missed. Claude's transcript is found through the `session_id` in its JSON usage file, so
it needs `~/.claude` (or `CLAUDE_CONFIG_DIR`) on the machine that ran the session.

`report.sh`, `pool-status.sh` and tier escalation all read `sessions.jsonl` through
`lib/jsonl.py`, which refuses (raises `ValueError`) any path that resolves outside the
project's `LOG_DIR`, symlinks and `..` included. Unparseable lines are skipped, and a
missing file reads as empty.

Pool refusals are recorded (`termination: pool-refused`, exit 90) so they can be
counted, but `report.sh` and `pool-status.sh` leave them out of cost and burn. A
tier that resolves to nothing affordable refuses before a project is loaded and is
not recorded.

## Per-item state file (`<LOG_DIR>/state/`)

The launcher cannot see or rewrite a hosted CLI's context, but it does choose what a
**new session** starts with. Each work item gets a small structured file that carries
what one session learned to the next, in place of the previous transcript:

`<LOG_DIR>/state/<project>-<issue|pr>-<N>.json` (`run-issue.sh` uses `issue`, `run-pr.sh` uses `pr`)

```json
{
  "goal": "...",
  "facts": ["..."],
  "files_modified": [{"path": "...", "change": "..."}],
  "errors": [{"what": "...", "cause": "...", "dead_end": true}],
  "next_step": "..."
}
```

- **The agent maintains it.** Every `run-issue.sh` / `run-pr.sh` prompt tells the session to
  keep `goal`, `facts`, `errors` and `next_step` current and final before it exits, even when
  it stops early or blocked (the same pattern as the `..._RESULT:` line, but a file). The file
  lives outside the worktree, like `STATUS_FILE`.
- **`files_modified` is the launcher's.** After the run it is rewritten from
  `git diff --name-status origin/<base>...HEAD`, whatever the agent put there (and dropped if
  git cannot answer, so an agent-reported list is never mistaken for git's).
- **The launcher validates it after the run**, next to the worktree and stray-PR checks, and logs
  one line, never failing the run: `STATE_OK`, `STATE_STALE` (valid but this session did not touch
  it), `STATE_INVALID` (missing, unparseable, or wrong shape), or `STATE_UNCHECKED` (no python on
  PATH). Validation needs `python3`/`python`; `lib/state.py` holds the schema.
- **The next session is seeded from it.** If a valid state file exists, the prompt gets it as a
  "carried-over state" block after the task, and every `errors[]` entry with `"dead_end": true`
  becomes an explicit "do not retry these" list. An invalid file is logged and skipped, not
  passed on. `run-issue.sh` re-runs and every `run-pr.sh` round are seeded this way.
- **Recorded in `sessions.jsonl`** as `state_seeded` (did this session start from one) and
  `state` (`valid` / `stale` / `invalid` / `missing`; both `null` for runs that have no state
  file, such as refine and verify), so `report.sh` can later compare retry rates with and
  without it.

Fields are trimmed when injected (long entries clipped, lists capped), so a state file that
has grown cannot bloat the next session's prompt.

## Dead-end ledger and tier escalation

The state file above is where the ledger lives -- there is no separate ledger file. What
changed is who writes to it. Until now only the agent added `errors[]` entries; the launcher
now merges in what *it* observed, so a session that crashes or gets killed before writing
anything still leaves a record for the next one:

- A [watchdog](#watchdog) kill appends its own entry (`dead_end: false` -- the approach may
  still be valid, it just ran out of time).
- Any other hard failure (non-zero exit, or a clean exit that still reported `FAILED`) appends
  `"session failed"` with `dead_end: true`: a retry at the same tier and backend, unchanged,
  would most likely just fail the same way again. A stronger tier is a different approach, so
  this does not block escalation, only an identical retry.

Both carry `git status`, `git diff --stat`, unpushed commits and a log tail, gathered by
`lib/escalation.sh` / `lib/state.sh` (`state_record_watchdog`, `state_record_attempt_failure`)
and appended via `lib/state.py`'s `watchdog` / `attempt-failed` subcommands, the same way a
missing state file is started from a minimal skeleton rather than losing the record.

**Escalation.** After a tiered run (`--tier`) via `run-issue.sh` or `run-pr.sh` finishes,
`lib/escalation.py` counts this item's *consecutive* failed attempts at its current tier from
`sessions.jsonl` (a clean `PUSHED`/`NO_CHANGE` resets the count; a `pool-refused` row is skipped
entirely -- it never ran). At `AGENT_ESCALATE_AFTER` (default **2**) the launcher prints:

```
ESCALATE_SUGGESTED: issue-42 failed 2 times at mechanical; next: standard
```

or, once already at the top of the ladder (`mechanical -> standard -> frontier`):

```
ESCALATE_EXHAUSTED: issue-42 failed 2 times at frontier (top tier); needs human attention
```

**Suggesting is the default.** `AGENT_AUTO_ESCALATE=1` / `--auto-escalate` lets the launcher
actually re-dispatch itself at the next tier once the current run's log is closed (`--new-session`
is added automatically for a `fix-findings` round, since a tier bump is a fresh attempt). This
still goes through the normal pool pre-flight check -- escalation never bypasses "the pool cannot
afford this" -- and terminates on its own: the ladder has at most two hops, each gated on a fresh
failure count, so it cannot loop.

`report.sh` shows a "Tier escalation" table: how many items ran on a tier, how many escalated
past their first one, and what share of those went on to merge.

## Pool routing (`pools.yaml`, `pool-status.sh`)

`pools.yaml` holds each plan-included usage pool and the routes that draw on
it. Edit the numbers there; no code reads them anywhere else.

```sh
bash pool-status.sh --project <name>
```

```
POOL              USED  LEFT RESETS             DAYS  CHEAPEST ROUTE   PCT/SES  SESSIONS  BURN/DAY  PROJECTED
cursor-models      86%   14% 2026-09-29          9.2  grok-low            0.02      ~700     0.13%        87%
chatgpt-pro        60%   40% 2026-09-24T20:00    5.0  sol-medium          3.00       ~13    35.31%       238%  OVER
claude-pro         18%   82% 2026-09-25T08:00    5.5  opus-medium            ?         ?         ?          ?
restricted-plan      -     - -                     -  OFF LIMITS             -         -         -          -
```

**Percent is comparable only within a pool.** What makes routes comparable is
`pct_per_session` — how much of a pool one session actually consumes. On the
numbers above, the pool that looks nearly spent (86%) has ~700 sessions left,
and the one that looks comfortable (60%) has ~13. Route by `PCT/SES`: take the
cheapest route that clears the task's bar and escalate only on failure, since
a failed cheap attempt costs a fraction of one expensive session.

Each route records how much to trust its rate — `measured`, `estimated` or
`unknown` — and `pools.yaml` writes down how each was derived. A route that
has never run stays `unknown`, and the tool declines to project it rather than
inventing a number. Burn rate is averaged over the current cycle only
(`cycle_days`), because a session from the previous cycle was paid out of a
balance that has since reset.

Snapshots go stale silently, so the script warns when `snapshot:` is more than
a day old. Update `used_pct` and `snapshot` together whenever you read the
real figures from a provider's dashboard.

**A pool can be reserved.** `reserve_pct` holds capacity back for something
other than this loop. `claude-pro` carries one because it is the pool the
*orchestrator* runs on — the queue-owner agent, any interactive Claude Code
session driving the loop, and background review automation all draw on it.
Measured 2026-09-19, it went 18% to 26% in about four hours of orchestration
with no headless session at all. Spending that pool down to zero strands the
thing doing the spending, so `LEFT` reports what is *spendable*, not the raw
remainder.

An uncalibrated route on a reserved pool is refused rather than run: a reserve
means "be careful here", and being careful with a cost you cannot predict means
not spending it. Calibrate such a route deliberately — lower the reserve for
one run — instead of discovering its rate by eating the reserve.

**A pool may be toppable.** `topup:` records that more plan capacity can be
bought — for `chatgpt-pro`, a cycle reset for about $8, far cheaper than a Max
plan. Buying plan capacity is not an API-billed fallback; it is more of the
same plan. But **the loop never buys anything**: it refuses and queues, and the
refusal simply carries the owner's own option with it instead of reading as a
dead end:

```
POOL_LOW: chatgpt-pro has 10% spendable, about 2.3 more 'sol-high' sessions.
Resets 2026-09-24T20:00. A $8 top-up restores 100% (about 23 more sessions
at this route's rate).
```

**Routes are matched by model, not just backend and effort.** Cursor at
`effort: high` is `grok-high` or Sol-via-Cursor depending on the model, and
those are different pools at wildly different costs, so the resolved model
decides which route a launch is priced against.

**The launchers enforce this, they don't just report it.** Every run
pre-flights its route and refuses to start when the pool can't afford one more
session, exiting **90** before creating a worktree, a log or a session:

```
POOL_SPENT: chatgpt-pro has 2% left, below the 4.30% one 'sol-high' session
costs. Queue or pause this work -- do not fall back to a paid route.
Resets 2026-09-24T20:00.
```

That is the "plan-included usage only" rule made mechanical: when a pool is
spent the work waits for the reset. There is deliberately **no override
flag** — if a refusal is wrong, the fix is to re-read the dashboard and update
`pools.yaml`, which is also what keeps the numbers honest. A pool with fewer
than three sessions left logs `POOL_LOW` and proceeds; an uncalibrated route
logs `POOL_UNCALIBRATED` and proceeds, since that session is what calibrates
it. Without a `pools.yaml`, or without python, the check is skipped entirely
and the launcher behaves as before.

## What the work cost (`report.sh`)

`report.sh` joins the session log to real merge outcomes — a PR's state from
`gh`, an issue's from whether the branch it pushed reached the default branch —
and reports cost per item, per route, and how much of the merged work never
needed a frontier session. Outcomes are cached in `<LOG_DIR>/outcomes.json`;
`--no-refresh` reuses them.

After the cost tables it prints how the sessions went: retry rate, compactions and
tool-output size by backend and tier, the same split by whether the session started
from a [state file](#per-item-state-file-log_dirstate), how sessions ended, and review
rounds per merged PR. Averages cover only the sessions that could report the field
and say how many that was. `backfill-sessions.sh` fills these fields for old codex logs
(and for claude runs that left a usage file), which gives a baseline from history.

Cost is in pool points, the only unit comparable across providers. A session on
an uncalibrated route is counted but not priced, and the report says how many
those were rather than treating them as free.

Read the "Grok-suitable" block as **what was routed where and whether it
merged** — not as proof of what each item needed. An item only shows as
"needed frontier" because a frontier session was pointed at it, which is a
routing choice, not a measurement. Establishing necessity takes the controlled
comparison: run representative issues on a cheap route and see which come back
needing rework.

## Verifying backends cheaply (`verify-backends.sh`)

"Does the codex backend work" and "can this model do the work" are different
questions, and only the second needs a real session. Verifying wiring with a
representative workload is expensive: on 2026-09-19 a backend-routing feature
was tested by running full PR reviews on each backend, which cost roughly seven
frontier sessions — 30 points of a weekly pool — to answer something a one-word
prompt answers.

```sh
bash verify-backends.sh --project myproject --backend cursor
```
```
BACKEND  RESULT   SECONDS     TOKENS       COST  REPLY
cursor   OK             9          -          -  READY
```

Every probe uses the lowest effort the backend offers, a prompt that needs no
tools and no repository, and a scratch directory rather than a worktree. Each
one is recorded in `sessions.jsonl` as `kind: verify`, so the cost of checking
sits next to the cost of working instead of being invisible overhead.

An off-limits pool is still refused. A merely low one is reported and probed
anyway — a probe is orders of magnitude smaller than a session, and being
unable to find out whether a backend works because its pool is low is worse
than the probe's own cost.

## Launch pacing

Launching several sessions at once has two observed failure modes: cursor-agent
races on its own `.cursor/cli-config.json` (EPERM on rename), and a burst trips
the provider's rate limiter (`RetriableError: resource_exhausted`). Four
fix-findings sessions launched in the same second once died without touching
their branches.

So each launcher takes a slot before starting: at most `MAX_CONCURRENT` in
flight, and at least `LAUNCH_STAGGER` seconds between launches on the same
backend. A run that cannot get a slot within 10 minutes prints
`CONCURRENCY_TIMEOUT` and exits **89** rather than waiting forever.

Slots are files named for the launcher's pid, so a crashed run frees its own
slot: the next launcher through prunes any slot whose process is gone. There is
no cleanup step and nothing to reset by hand.

## Watchdog

Crashed or stalled sessions do not recover on their own. Cursor is the worst
offender (it halts on limits and hangs), but any backend can wedge, and
nothing else bounds a session's runtime -- a wedged session holds a
concurrency slot and a worktree and produces nothing until a human notices.
`run-issue.sh` and `run-pr.sh` (`lib/watchdog.sh`) wrap every backend
invocation with two checks:

- **Hard ceiling** -- `--timeout <minutes>` / `AGENT_TIMEOUT_MIN`, default 45
  (cursor), 60 (codex) or 90 (claude). Kills the session once it has run this
  long regardless of activity.
- **Stall check** -- `--stall <minutes>` / `AGENT_STALL_MIN`, default 10 for
  every backend. Kills the session early if its log has not grown *and* the
  worktree (branch tip plus working-tree status) has not changed for this
  long. This is the check that actually catches a hang in minutes; a ceiling
  alone either kills legitimate long runs or waits too long on a real one.

The defaults come from real session durations in `sessions.jsonl`
(2026-09-22 snapshot): cursor's 95th percentile sits near 30 minutes with a
handful of outliers past 68 minutes, codex tops out at 46 minutes, and 45/60
minute ceilings clear those with room while still catching a genuine hang. A
flat 15-minute ceiling, floated when this was proposed, would have killed
roughly one in ten real cursor sessions outright.

**Enabled by default for cursor only** (`AGENT_WATCHDOG=1` turns it on for any
backend, `AGENT_WATCHDOG=0` forces it off; passing `--timeout` or `--stall`
also turns it on). Codex and claude have not shown the same hang behavior, so
they stay unwatched unless asked for.

On a kill:

- The whole process tree is killed, not just the launcher's wrapper pid --
  `taskkill /T /F` on Windows (killing only the wrapper leaves `node.exe`
  running), a recursive `pgrep`-based signal on macOS/Linux.
- The worktree is left exactly as the kill left it -- nothing is discarded.
- `AGENT_WATCHDOG: killed after <reason>` is logged and the session exits
  **99**; `sessions.jsonl` records `termination: watchdog` instead of
  `failed`, so a kill is not counted as a normal failure.
- The [item's state file](#per-item-state-file-log_dirstate) gets an appended
  error entry with the kill reason, `git status`/`git diff --stat`, any
  unpushed commits and a log tail -- even if the killed session never wrote a
  state file itself -- so the next session or a human sees what was in flight
  without re-deriving it.
- A killed `fix-findings` run never printed a `PR_<N>_RESULT:` line, so it is
  not counted toward `run-pr.sh`'s review-round cap.

## Tests

```sh
python -m unittest discover -s tests
```

Run from the repo root. Currently covers `lib/jsonl.py` (`tests/test_jsonl.py`).

## Exit codes

| code | meaning |
|------|---------|
| 89 | could not get a launch slot within the wait limit |
| 90 | the target pool cannot afford another session (`POOL_SPENT`) |
| 91 | review-round cap reached; handoff brief written (`run-pr.sh`) |
| 92-98 | worktree, PR-state and prerequisite failures (96 is a missing `jq`/`python`; see each script) |
| 99 | the [watchdog](#watchdog) killed a stalled or over-ceiling session |

## Known rough edges

- `codex exec --sandbox <mode>` conflicts with `--approve-for-me` (the latter
  already implies workspace-write) — don't pass both.
- `cursor-agent --sandbox enabled` errors out on Windows ("Sandbox requires
  macOS or Linux"); the script already gates this by OS.
- A shared `.git` directory across worktrees can occasionally throw a
  transient `cannot lock ref ... Permission denied` under concurrent git
  activity (e.g. a CI runner touching the same repo). It's usually transient;
  retrying the git operation resolves it.
