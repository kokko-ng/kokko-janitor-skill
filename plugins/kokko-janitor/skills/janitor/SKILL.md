---
name: janitor
description: Whole-repository clean-up orchestrator - parallel lint fixes in git worktrees plus metric-ranked, judged god-module refactoring. Use only when the user asks to run the janitor, wants every quality check fixed across the whole repo, or asks for a hotspot or god-module analysis of the codebase; not for tidying one file or function.
argument-hint: '[target-branch] [--dry-run] [--hold | --resume] [--langs py,js,dotnet] [--checks security,types,...] [--no-design] [--top N] [--apply-design] [--max-rounds N]'
context: fork
background: false
---

# Janitor Skill

Make a codebase clean and keep it that way. Two layers:

1. **Lint layer** (deterministic): run the quality-check skills in parallel
   worktrees, one `kokko-janitor:worktree-worker` agent per worktree, fix
   everything they find, merge.
2. **Design layer** (judged): rank modules by god-module risk with
   deterministic metrics, have a worker judge the top candidates and propose
   splits, put every proposal to a three-judge panel, and gate any structural
   change behind tests and an API-surface check.

A metrics scorecard ratchets structural quality so it can only improve
across runs, and a run-state file makes every run resumable.

This skill runs in a forked context: worker reports, judge votes, and merge
output stay out of the caller's conversation, which receives only the final
report. Nobody can answer a question mid-run, so every decision point below
either continues or stops and reports.

## Arguments

Parse `$ARGUMENTS` for:

- `target-branch` - branch to merge fixes into (default: current branch)
- `--dry-run` - run the ranking and every check in REPORT-ONLY mode on the
  main checkout: no worktrees, no branches, no commits, no run-state file.
  Reports what a full run would fix; the steering point before a big run
- `--hold` - stop after the lint and design layers with every `janitor/*`
  branch and worktree kept for review, and print the merge commands.
  Continue later with `--resume`
- `--resume` - continue the run recorded in `.janitor/run.json` from the
  phase it stopped in, whether a hold, a crash, or a lost context
- `--langs` - languages to check (default: `languages` in `.kokko.json`,
  else auto-detect every language present)
- `--checks` - lint checks to run (default: `checks` in `.kokko.json`, else
  all)
- `--no-design` - skip the design layer entirely
- `--top N` - design candidates to judge (default: `janitor.top` in
  `.kokko.json`, else 3). Slices the Phase 0 output; the hotspot script
  itself always runs with `--top 20`
- `--apply-design` - apply approved design refactors. Without it the design
  layer is REPORT-ONLY: it produces split plans and never edits
- `--max-rounds N` - convergence rounds (default: `janitor.max_rounds` in
  `.kokko.json`, else 1; each extra round re-ranks hotspots after merging
  and continues while candidates remain)

`.kokko.json` at the repo root is the optional per-repo config shared with
the kokko-code-quality skills; read it with `jq` first when it exists. An
explicit flag always wins over the config.

## Lint Checks

Provided by the `kokko-code-quality` plugin (required for the lint layer):
`security`, `types`, `complexity`, `deadcode`, `docs`, `architecture`.
`architecture` supports py and js only. Every check accepts `--report` for
report-only runs, which is what `--dry-run` relies on.

## Agents

Three plugin agents carry the subagent contracts, git rules included, so
briefs stay short:

| Agent | Role | Tools |
| ----- | ---- | ----- |
| `kokko-janitor:worktree-worker` | Runs one check or the design skill in one worktree, commits by explicit path | inherits the session's |
| `kokko-janitor:design-judge` | Reads one module and one plan, votes ACCEPT or REJECT | Read, Grep, Glob only |
| `kokko-janitor:pass-runner` | One fresh multipass pass (used by `multipass`, not here) | inherits the session's |

Spawn them by those names. A brief needs only the worktree, branch, skill
invocation, language, and evidence; the agent already knows the rules.

## Git rules for the orchestrator

Workers carry the full rules; the orchestrator merges and cleans up, so it
keeps the same ones. Stage explicit paths only. Never stash, clean, reset,
rebase, or restore against a dirty tree. Never push, never rewrite history,
never `--force` a worktree removal, never `-D` a branch. A dirty tree at any
point where a clean one is required: stop and report, never tidy.

## Run state

`.janitor/run.json` records the run so it survives a crash, a compaction, or
a `--hold`; `references/worktree-workflow.md#run-state` has the schema.
Write it when Phase 1 starts, update it at every phase boundary and every
worker completion, and delete it in Cleanup. It is untracked and ignored
through `.git/info/exclude`.

## Workflow

Read `references/worktree-workflow.md` for worktree mechanics, run-state
handling, hold and resume, merge strategy, conflict handling, and error
recovery.

### Preflight

1. Resolve config and flags. With `--resume`: load `.janitor/run.json`,
   verify every recorded worktree and branch still exists, and continue from
   the recorded phase. A missing file or a mismatch means stop and report.
2. Without `--resume`: look for leftovers of an earlier run
   (`git worktree list --porcelain`, `git branch --list 'janitor/*'`,
   `.janitor/run.json`). Anything found means stop and report it with the
   exact recovery commands from the reference. Never delete leftovers
   yourself: they may hold fixes nobody collected.
3. Verify a clean working tree. `--dry-run` skips this check because it
   changes nothing.

### Phase 0: Hotspot Ranking (deterministic)

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/hotspots.py" . --top 20 \
  --scorecard .janitor/scorecard.json
```

Always run with `--top 20`; the user-facing `--top N` selects how many of
the returned `candidate: true` files Phase 2 judges. The script reads
`excludes` and the candidate thresholds from `.kokko.json` on its own.

Produces a ranked list of god-module candidates (LOC, defs, fan-in/out,
churn, composite score) plus cross-package temporal-coupling pairs, and
compares structural metrics against the scorecard baseline (exit 2 means
the codebase regressed since the last run: report this prominently).

Keep the JSON output; it feeds the design briefs and the final report.

### Phase 1: Lint Layer

With `--dry-run`: detect languages, then spawn one `worktree-worker` per
language/check pair on the main checkout, all in parallel, each with a
REPORT-ONLY brief running `/kokko-code-quality:<check> <lang> --report`.
Collect the findings and go straight to the Final Report; nothing else runs.

Otherwise:

1. Detect languages; create `WORKTREE_BASE=$(mktemp -d)`; write
   `.janitor/run.json` with phase `lint`.
2. One worktree + branch per language/check pair:
   `git worktree add $WORKTREE_BASE/<lang>-<check> -b janitor/<lang>-<check>`,
   recorded in the run state as you go.
3. One `worktree-worker` per worktree, all in parallel: languages x checks
   workers in total. Do not fold two languages into one worker: each
   worktree holds exactly one language's fixes for one check, which is what
   keeps every branch reviewable and mergeable on its own. The brief names
   the worktree, the branch, and `/kokko-code-quality:<check> <lang>`; the
   worker fixes all findings and commits in the check's own message format.
   Record each worker's result (clean, fixed with N commits, failed) in the
   run state as it finishes; that report is the only record of what it did.

### Phase 2: Design Layer

Skip if `--no-design`, or if Phase 0 found no file with `candidate: true`
(the absolute loc/defs gate; the normalized score only orders candidates and
always puts some file near 1.0). Record phase `design`.

1. For each of the first N `candidate: true` files, create a worktree and
   branch (`janitor/design-<stem>`) and spawn a `worktree-worker` running
   `/kokko-janitor:design <path>` with the candidate's metric evidence
   pasted into the brief. The design skill produces a verdict (`god-module`
   or `cohesive`) and, for god modules, a split plan written to
   `.janitor/design-plan-<stem>.md` inside the worktree. "Cohesive, no
   action" is a valid and common outcome.
2. **Judge panel**: for each `god-module` verdict, spawn three
   `kokko-janitor:design-judge` agents in parallel, each briefed with the
   module path, the plan path (absolute, inside the worktree), and the
   metric evidence. Majority rules. Rejected plans still appear in the
   final report, marked rejected, with the judges' reasons.
3. **Collect plans before any cleanup**: copy every
   `.janitor/design-plan-*.md` from the design worktrees into the main
   checkout's `.janitor/` directory. Removing a worktree destroys its
   contents; a plan not copied out first is lost. The copies are untracked
   and ignored through `.git/info/exclude`; leave them for the user.
4. Only with `--apply-design`: for each ACCEPTED plan, the same worker
   applies it under the design skill's apply-mode gates (characterization
   coverage, public API snapshot, full test suite). Without the flag, plans
   land in the report only.

### Hold point

With `--hold`, or when resuming a held run before anything has merged:
record phase `hold`, leave every worktree and branch in place, and stop with
a per-branch summary (commits, what changed, clean or fixed) plus the exact
merge commands from the reference. Nothing merges until `--resume`.

### Phase 3: Merge and Validate

Record phase `merge`.

1. Merge lint branches first (smallest changesets first), then any applied
   design branches, all `--no-ff`, preserving individual commits. Mark each
   branch merged in the run state.
2. Resolve conflicts preserving both intents; stage only the conflicted
   files by explicit path.
3. Final validation on the merged result: run every lint tool that ran in
   Phase 1 plus the full test suite. For applied design changes, also
   verify the public API surface is unchanged (`griffe dump` before and
   after when available). Any regression: fix it before finishing; never
   leave a failing state merged.
4. Test runs may regenerate tracked build artifacts (dbt `target/`, bundler
   output) polluted with ephemeral test values. Never commit those; report
   them and suggest ignoring the artifact paths.

### Phase 4: Ratchet and Converge

Record phase `ratchet`.

1. Re-run the Phase 0 script with `--update` to tighten
   `.janitor/scorecard.json` to the new values, and commit the scorecard
   change if the file is tracked or the user asked for it to be tracked.
2. If `--max-rounds` allows another round AND Phase 2/3 landed changes AND
   `candidate: true` files remain, loop back to Phase 0 with `round`
   incremented. Stop when a round lands nothing (converged).

### Cleanup

Remove all worktrees with plain `git worktree remove`, never `--force` (a
refusal means the worktree still holds uncollected files: inspect, collect,
retry). Delete all `janitor/*` branches with `git branch -d`; merged and
zero-commit branches both delete cleanly, and a `-d` refusal means unmerged
commits, which is a finding to report, never a reason for `-D`. Finally
delete `.janitor/run.json` and record nothing else: a run that reaches this
point is complete.

## Final Report

- Mode (`dry-run`, `hold`, resumed, full) and the round count
- Per-check lint results, including "clean"; in a dry run, the findings
  each check would fix
- Hotspot top 20 with scores and candidate flags; scorecard delta
  (improved, regressed, or held)
- Design verdicts, judge votes with reasons, plans applied or proposed,
  rejections
- Temporal-coupling pairs worth a human look
- Anything skipped and why, and for a hold the exact commands to continue

## Success Criteria

- All lint issues fixed, all merges clean, final validation passes
- Design layer: every candidate has a verdict; no structural change merged
  without passing its gates; report-only unless `--apply-design`
- Scorecard never regresses silently
- No run leaves worktrees, branches, or a run-state file behind unless it
  stopped at a hold or reported a blocker
