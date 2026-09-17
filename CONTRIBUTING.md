# Contributing

## Local checks

```bash
python3 -m pytest tests/ -q          # hotspots + progress-guard tests (real repos and subprocesses, no mocks)
pre-commit install                   # once; then hooks run on every commit
pre-commit run --all-files           # ruff + ruff-format, markdownlint, shellcheck, hygiene
bash scripts/check-marketplace-sync.sh
bash scripts/lint-prompts.sh         # skill and agent frontmatter, placeholders, cited paths, fork rules
bash scripts/check-cross-repo-refs.sh ../kokko-skills   # every /kokko-code-quality:<check> citation resolves
claude plugin validate plugins/kokko-janitor
```

Dev dependencies are pinned in `requirements-dev.txt`
(`pip install -r requirements-dev.txt`). Ruff is configured in
`pyproject.toml` and runs via its pre-commit hook; there is no separate
CI job for it.

`plugins/kokko-janitor/scripts/hotspots.py` is stdlib-only by design
(the README promises it); do not add runtime dependencies. New or
changed script behavior gets a test in `tests/test_hotspots.py`,
following the house style there: real git repos via the helpers, the
script run as a subprocess, JSON parsed, no mocks. The progress-guard
hook is tested the same way in `tests/test_progress_guard.py`.

## Layout

- `skills/<name>/SKILL.md`: the three user-facing skills. `janitor` runs
  forked (`context: fork`, `background: false`); `multipass` stays inline
  because a pass may run the janitor and nested subagents are capped at
  three layers.
- `agents/<name>.md`: the worker, judge, and pass-runner contracts. The
  git rules live here, once; a skill brief names only the worktree,
  branch, skill invocation, and evidence.
- `hooks/`: the progress guard (`hooks.json` registers it for Stop and
  SubagentStop).

## Release flow (CI-gated)

1. Bump the version in BOTH `.claude-plugin/marketplace.json` and
   `plugins/kokko-janitor/.claude-plugin/plugin.json` (they must agree;
   `scripts/check-marketplace-sync.sh` enforces it), then merge to `main`.
2. CI runs on `main` (pre-commit, actionlint, pytest, plugin validation,
   prompt lint, cross-repo reference check, sync check).
3. When CI succeeds, `.github/workflows/release.yml` fires via
   `workflow_run` and creates the `v<version>` GitHub release. It is the
   sole publisher; never run `gh release create` by hand.
   `workflow_dispatch` with an explicit tag exists for recovery.

## Shared infrastructure

The shared infra here (release workflow, marketplace sync script, prompt
linter, pre-commit config, gitignore) follows
[kokko-skills](https://github.com/kokko-ng/kokko-skills), which holds the
reference copies. When changing any of it, keep the two repos convergent.
The CI job that checks cross-repo references clones kokko-skills next to
this repo, so the check skills the janitor cites can never silently
disappear.
