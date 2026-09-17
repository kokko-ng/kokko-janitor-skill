---
name: multipass
description: Run N independent fresh-context passes of a skill or prompt file, sequentially, and report convergence. Use when the user asks to run something several times, to verify a clean-up converged, or to run a tailored validation prompt from prompts/.
argument-hint: '<N> <skill-or-prompt-file> [then <N> <target> ...] [--pre "<step>"] [--dry-run]'
disable-model-invocation: true
---

# Multipass Skill

Run a set of prompts together: N independent passes of each target, fully
sequentially, each pass in a fresh `kokko-janitor:pass-runner` agent with no
context from previous passes. Independent repetition is a verification
tool: a finding that appears in two independent passes is probably real,
and a pass that finds nothing after a pass that fixed everything is
evidence of convergence.

This skill runs inline, not forked, on purpose: a pass may itself run the
janitor, which forks and spawns its own workers, and nested subagents are
capped at three layers below the conversation.

## Arguments

Parse `$ARGUMENTS` as an ordered plan:

- `<N> <target>`: N passes of a target. A target is either a namespaced
  skill invocation (`/kokko-janitor:janitor`,
  `/kokko-code-quality:security py`; a bare short name like `/security`
  only resolves while no other plugin claims it) or a prompt file path
  (`prompts/deployed-validation.md`)
- `then` chains further targets: `2 prompts/a.md then 2 prompts/b.md` runs
  a1, a2, b1, b2, strictly in that order
- `--pre "<step>"`: a step to perform ONCE before the first pass (for
  example "deploy the code exactly as it currently exists, with no changes")
- `--dry-run`: print the parsed plan and stop

Always print the parsed plan as a numbered table (pass, target, kind) before
running anything, then proceed. Never stop to ask whether the plan is right:
a blocking question inside a long autonomous run is the worst of both
worlds, and `--dry-run` exists for checking the parse first. If the
arguments cannot be parsed at all, report what was ambiguous and stop.

## Execution

Run `--pre` first if given. Then, for each pass in order:

1. Spawn ONE new `kokko-janitor:pass-runner` agent. Its brief is the target
   (the skill invocation, or "follow all directions in `<file>`") plus the
   ground facts below. The agent carries the git rules, the nothing-found
   rule, and permission to spawn its own subagents as the target requires.
2. Wait for the pass to finish completely before starting the next. Never
   run passes in parallel: later passes must see the repo state earlier
   passes produced.
3. After each pass, verify repo hygiene before continuing: tracked tree
   state, no leftover worktrees or `janitor/*` branches, no stray
   `.janitor/run.json`. Verify and report; never tidy. A dirty tree that is
   not yours stops the run.

### Context between passes

Passes are independent, but not blind: brief each pass with the few GROUND
FACTS later passes need to avoid re-deriving or contradicting reality ("the
tree is clean", "generated artifacts under X are expected and must be left
alone", "a previous pass already fixed the lint baseline, expect little").
Never leak a previous pass's findings or conclusions, only environmental
facts. That preserves independence while preventing wasted passes.

### Progress guard

This plugin ships a Stop/SubagentStop hook. While a `prompts/*-progress.md`
in the working directory was touched in the last 30 minutes and still lists
`pending`, `in-progress`, or `open` items, a pass that tries to stop is
sent back to work once per change of that file. It never blocks twice
without progress in between, and `blocked` items count as done, so the
prompts' stuck rule remains the way out. `KOKKO_PROGRESS_GUARD=off`
disables it.

## Git rules for the orchestrator

The pass runner carries the full rules. The orchestrator itself changes
nothing in the repo between passes: no staging, no commits, no clean-up.

## Final Report

- The plan as parsed, and per pass: what ran, what it found, what changed
  (commits and branches)
- **Convergence analysis**: did successive passes of the same target find
  less? A first pass with many findings, a second with few, and a third
  with none is the ideal signature. Identical findings across passes that
  nobody fixed indicate a blocked fix, not noise: flag them.
- Discrepancies: anything one pass claimed that another contradicted
- Repo state at the end: branch, HEAD, cleanliness
