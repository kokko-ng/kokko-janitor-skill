# kokko-janitor

A Claude Code plugin that makes a codebase clean and keeps it that way.

Two layers, because deterministic tools and LLM judgment are good at
different things:

1. **Lint layer** (deterministic). Runs quality checks (security, types,
   complexity, dead code, docs, architecture) in parallel git worktrees,
   one worker agent per check, fixes everything found, and merges the
   results as reviewable `--no-ff` merges of small logical commits.
2. **Design layer** (deterministic finds, LLM judges, tests gate). Linters
   cannot see a god module: a 2,000-line file of individually clean
   functions passes every check. This layer ranks modules by god-module
   risk using objective signals (LOC, definition count, import fan-in/out,
   git churn, cross-package temporal coupling), then has an agent judge
   only the top candidates. A three-judge panel of read-only agents votes
   on every proposed split; structural changes are report-only by default
   and, when applied, are gated behind characterization-test coverage, a
   public-API snapshot, and the full test suite.

A committed scorecard (`.janitor/scorecard.json`) ratchets structural
metrics (max file size, max fan-in, max definitions per file) so the
codebase can only get better between runs, and a run-state file
(`.janitor/run.json`) makes every run resumable.

## Install

```text
/plugin marketplace add kokko-ng/kokko-janitor-skill
/plugin install kokko-janitor@kokko-ng-kokko-janitor
```

The marketplace ID stays `kokko-ng-kokko-janitor` (the repository was
named kokko-janitor until 2026-09-15), so existing installs keep working
unchanged.

The lint layer invokes the check skills from
[kokko-skills](https://github.com/kokko-ng/kokko-skills)' `kokko-code-quality`
plugin; install that too, or run with the design layer only.

## Usage

```text
/kokko-janitor:janitor --dry-run             # what a full run would fix; changes nothing
/kokko-janitor:janitor                       # lint fixes + design report, merged
/kokko-janitor:janitor --hold                # fix in worktrees, keep the branches for review
/kokko-janitor:janitor --resume              # continue a held or interrupted run
/kokko-janitor:janitor --apply-design        # also apply approved splits
/kokko-janitor:janitor --no-design           # lint layer only
/kokko-janitor:janitor --langs py,js         # limit languages (default: .kokko.json, else auto-detect)
/kokko-janitor:janitor --checks security,types   # limit lint checks (default: .kokko.json, else all)
/kokko-janitor:janitor --top 5 --max-rounds 3    # deeper, iterative
/kokko-janitor:design src/big_module.py      # judge one module directly
/kokko-janitor:multipass 3 /kokko-janitor:janitor            # 3 fresh-context passes, convergence report
/kokko-janitor:multipass 2 prompts/deployed-validation.md then 2 prompts/aesthetics.md
/kokko-janitor:multipass --dry-run 2 prompts/a.md then 1 prompts/b.md   # print the parsed plan only
```

The janitor runs forked: its worker reports, judge votes, and merge output
stay out of your conversation and you receive the final report. It never
asks a question mid-run; every decision point either continues or stops
with a report and the exact command to continue. `--dry-run` is the
steering point before a big run, `--hold` the checkpoint after one.

A run that crashes or loses its context leaves `.janitor/run.json`, its
worktrees, and its `janitor/*` branches in place. The next run detects
them and stops with recovery commands; `--resume` continues from the
recorded phase. Nothing is ever deleted automatically: a branch may hold
fixes nobody collected.

## Agents

The subagent contracts, git rules included, live in three plugin agents
rather than in prose pasted into every brief:

| Agent | Role | Tools |
| ----- | ---- | ----- |
| `kokko-janitor:worktree-worker` | Runs one check or the design skill in one worktree, commits by explicit path | inherits |
| `kokko-janitor:design-judge` | Reads a module and its split plan, votes ACCEPT or REJECT, with reasons | Read, Grep, Glob only |
| `kokko-janitor:pass-runner` | One fresh multipass pass, no memory of earlier passes | inherits |

## Per-repo configuration

An optional `.kokko.json` at the repo root, shared with kokko-skills'
check skills. Flags always win over the file.

```json
{
  "languages": ["py", "js"],
  "checks": ["security", "types", "complexity", "deadcode", "docs", "architecture"],
  "excludes": ["*/generated/*"],
  "janitor": {"top": 3, "max_rounds": 1, "candidate_loc": 400, "candidate_defs": 30}
}
```

## Hotspot ranker

The ranker is a plain script and useful on its own. With the plugin
installed:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/hotspots.py" . --top 10
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/hotspots.py" . --scorecard .janitor/scorecard.json --update
```

(When developing in this repo, the same script lives at
`plugins/kokko-janitor/scripts/hotspots.py`.)

Stdlib-only Python; needs `git` on PATH. It analyses Python with `ast` and
JavaScript, TypeScript, and Vue single-file components with regexes over
the script source, so `defs`, `fan_in`, and `fan_out` are populated for
both stacks. It reads `excludes` and the candidate thresholds from
`.kokko.json` (`--config` to point elsewhere). Exit 2 means a scorecard
regression.

## Multipass

`multipass` runs repeated independent passes of any skill or prompt file
(sequentially, each in a fresh `pass-runner` agent) and reports
convergence: a first pass that finds much, a second that finds little, and
a third that finds nothing is evidence the codebase is actually clean; the
same finding surviving multiple passes unfixed is evidence of a blocker.
Chain targets with `then` to run ordered sets, `--pre '...'` for a one-time
setup step (e.g. deploy before validating), and `--dry-run` to print the
parsed plan. It pairs with the `tailor` skill from kokko-skills'
kokko-validation plugin, which writes repo-specific prompt files to
`prompts/`.

Multipass runs inline on purpose: a pass may run the janitor, which forks
and spawns its own workers, and nested subagents are capped at three
layers below the conversation.

## Progress guard

The plugin ships a Stop/SubagentStop hook. While a `prompts/*-progress.md`
in the working directory was touched in the last 30 minutes and still
lists `pending`, `in-progress`, or `open` items, an agent that tries to
stop is sent back to work, once per change of that file. It never blocks
twice without progress in between, `blocked` items count as done (the
prompts' stuck rule remains the way out), and a stale file never blocks
anything.

| Environment Variable | Default | Purpose |
| -------------------- | ------- | ------- |
| `KOKKO_PROGRESS_GUARD` | `on` | Set to `off` to disable the hook |
| `KOKKO_PROGRESS_GUARD_MINUTES` | `30` | How recently a progress file must have changed to count |

## Design principles

- **Deterministic finds, LLM judges, tests gate.** Metrics rank
  candidates; agents decide god-module vs cohesive; nothing structural
  merges without passing its gates. "Cohesive, no action" is an expected
  verdict, not a failure.
- **Report-first.** A bad lint fix costs nothing; a bad module split costs
  a day. Design changes need `--apply-design` plus a majority of judges,
  and a full run can be previewed with `--dry-run` and checkpointed with
  `--hold`.
- **Never manufacture work.** Clean checks report clean. Tool
  configurations are never relaxed to create findings.
- **Git safety.** No stash/reset/restore against dirty trees, no history
  rewrites, no pushes, explicit-file-path staging only, never `--force`
  or `-D`. Dirty tree means stop and report, not tidy and proceed. The
  rules live once, in the agents.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for the test suite, pre-commit
setup, ruff, and the CI-gated release flow. Shared infrastructure (release
workflow, sync script, prompt linter, pre-commit config) follows
[kokko-skills](https://github.com/kokko-ng/kokko-skills).

## License

MIT
