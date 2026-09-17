# Git Worktree Orchestration Workflow

Mechanics for the janitor skill: run state, preflight, worktrees, worker
briefs, hold and resume, merging, cleanup, and error recovery.

## Prerequisites

- Git repository with a clean working tree (a dry run needs only a
  repository)
- `jq` for reading `.kokko.json` and `.janitor/run.json`
- The `kokko-code-quality` plugin installed, for the lint layer

## Run state

`.janitor/run.json` is the one record of an in-flight run. It exists so a
crash, a compaction, or a `--hold` never strands worktrees nobody can find
again. Write it when Phase 1 starts, update it at every phase boundary and
every worker completion, and delete it in Cleanup.

```json
{
  "started": "2026-09-17T10:00:00Z",
  "target_branch": "main",
  "worktree_base": "/tmp/tmp.k3Qx1a",
  "args": {"langs": ["py"], "checks": ["security", "types"], "top": 3,
           "apply_design": false, "max_rounds": 1},
  "phase": "lint",
  "round": 1,
  "checks": {
    "py-security": {"worktree": "/tmp/tmp.k3Qx1a/py-security",
                    "branch": "janitor/py-security",
                    "status": "fixed", "commits": 2, "note": ""},
    "py-types": {"worktree": "/tmp/tmp.k3Qx1a/py-types",
                 "branch": "janitor/py-types",
                 "status": "running", "commits": 0, "note": ""}
  },
  "design": {
    "src/big.py": {"worktree": "/tmp/tmp.k3Qx1a/design-big",
                   "branch": "janitor/design-big",
                   "verdict": "god-module", "votes": ["ACCEPT", "REJECT", "ACCEPT"],
                   "plan": ".janitor/design-plan-big.md", "applied": false}
  }
}
```

`phase` is one of `lint`, `design`, `hold`, `merge`, `ratchet`. A check
`status` is `pending`, `running`, `clean`, `fixed`, `failed`, or `merged`.
Absolute paths only: a resumed run may start from a different shell.

Keep the file untracked and out of `git status` through the repository's
shared exclude file (never its tracked `.gitignore`):

```bash
# --git-path resolves to the shared info/exclude even inside a worktree
exclude="$(git rev-parse --git-path info/exclude)"
git check-ignore -q .janitor/run.json 2>/dev/null || echo '.janitor/run.json' >> "$exclude"
git check-ignore -q .janitor/design-plan-probe.md 2>/dev/null || echo '.janitor/design-plan-*.md' >> "$exclude"
```

Only those two patterns. The scorecard, `.janitor/scorecard.json`, is meant
to be committed, so a blanket `.janitor/` entry would hide a first-run
scorecard from `git status`.

## Preflight

```bash
# Per-repo config (optional); flags override every value
[ -f .kokko.json ] && jq '{languages, checks, janitor}' .kokko.json

# Leftovers of an earlier run
git worktree list --porcelain
git branch --list 'janitor/*'
ls .janitor/run.json 2>/dev/null

# Clean working tree (skipped by --dry-run)
git status --porcelain

# Current branch as the default target
git branch --show-current
```

Any `janitor/*` branch, any worktree under a previous `worktree_base`, or a
`run.json` without `--resume` means an earlier run did not finish. Stop and
report; do not clean up. Print exactly this for the user:

```text
A previous janitor run left work behind. Either continue it:
    /kokko-janitor:janitor --resume
or inspect and clear it by hand (each branch may hold uncollected fixes):
    git worktree list
    git log --oneline <target>..janitor/<name>       # per branch
    git worktree remove <path>                       # plain remove, never --force
    git branch -d janitor/<name>                     # -d, never -D
    rm .janitor/run.json
```

## Detect languages

```bash
# Explicit if-statements, not `[ ... ] || [ ... ] && echo`: that bare
# compound exits non-zero when the test fails, which aborts a `set -e`
# shell (and `A || B && C` groups as `(A || B) && C`, not `A || (B && C)`).
if [ -f pyproject.toml ] || [ -f setup.py ]; then echo "py"; fi
if [ -f package.json ] || [ -f tsconfig.json ]; then echo "js"; fi
if [ -n "$(git ls-files '*.csproj' '*.sln')" ]; then echo "dotnet"; fi
```

`languages` in `.kokko.json` or `--langs` replaces detection entirely.

## Create worktrees

```bash
WORKTREE_BASE=$(mktemp -d)
git worktree add "$WORKTREE_BASE/py-security" -b janitor/py-security
git worktree add "$WORKTREE_BASE/js-types" -b janitor/js-types
```

Create every worktree up front, recording each in `run.json`, then launch
all workers together.

## Launch workers

Spawn one `kokko-janitor:worktree-worker` agent per worktree, all in one
parallel batch. The agent carries the git rules and the worktree discipline
(absolute paths, `git -C`), so a brief is short:

```text
WORKTREE: /tmp/tmp.k3Qx1a/py-security
BRANCH: janitor/py-security
RUN: /kokko-code-quality:security py
Fix everything the check finds and commit in the check's own message format.
```

A dry-run brief differs in two lines:

```text
WORKTREE: <repo root>   (REPORT-ONLY: edit nothing, commit nothing)
RUN: /kokko-code-quality:security py --report
```

Design briefs add the evidence:

```text
WORKTREE: /tmp/tmp.k3Qx1a/design-big
BRANCH: janitor/design-big
RUN: /kokko-janitor:design src/big.py
EVIDENCE: <the candidate's row from the Phase 0 JSON, plus its coupling pairs>
```

Judge briefs go to `kokko-janitor:design-judge`, three per plan, in parallel:

```text
MODULE: /tmp/tmp.k3Qx1a/design-big/src/big.py
PLAN: /tmp/tmp.k3Qx1a/design-big/.janitor/design-plan-big.md
EVIDENCE: <same row>
```

## Monitor

Record each worker's final report in `run.json` as it lands: it is the only
record of what that worker found, fixed, and committed. Note failures and
blockers; count fixes per worker for the final report.

## Hold

With `--hold`, once every worker has reported: set `phase` to `hold`, keep
every worktree and branch, and stop with a summary table (branch, status,
commits, one-line description) and the merge commands below, ready to paste.
Nothing is merged, nothing is deleted.

## Resume

With `--resume`: load `run.json`, then verify before trusting it.

```bash
jq -r '.worktree_base, .phase, (.checks | to_entries[] | "\(.key) \(.value.branch) \(.value.status)")' .janitor/run.json
git worktree list --porcelain
git branch --list 'janitor/*'
```

Every recorded worktree path and branch must exist; a worktree that is gone
while its branch remains is fine (the commits are on the branch, recreate
the worktree only if a worker still has to run there). Then continue:

- `lint` or `design`: re-spawn workers only for checks not marked `clean`,
  `fixed`, or `merged`, and re-judge only plans without votes
- `hold`: continue to Merge and Validate
- `merge`: merge the branches not yet marked `merged`
- `ratchet`: run the ratchet, then Cleanup

## Merge strategy

```bash
git checkout <target-branch>
git merge janitor/py-security --no-ff -m "chore(quality): merge py security fixes"
git merge janitor/py-types --no-ff -m "chore(quality): merge py type fixes"
# ... smallest changesets first, applied design branches last
```

### Handling conflicts

1. Read both hunks and work out what each fix intended
2. Resolve preserving both intents; usually both are valid
3. Stage ONLY the conflicted files, by explicit path. Never `git add .` and
   never a directory add: untracked files beside tracked ones get swept in

```bash
git diff --name-only --diff-filter=U   # list conflicted files
git add -- <each-conflicted-file>
git commit -m "chore(quality): resolve merge conflict in <file>"
```

| Pattern | Resolution |
| ------- | ---------- |
| Same line modified | Keep both if independent, combine if related |
| Import ordering | Accept either, let the formatter fix |
| Adjacent lines | Both changes usually apply |
| Delete vs modify | Prefer the fix unless the delete was intentional |

## Final validation

```bash
# Python
uv run pre-commit run --all-files
# JavaScript/TypeScript
npm run lint
npm run build
# .NET
dotnet build -warnaserror
```

Without a `.pre-commit-config.yaml`, run the individual quality tools the
workers used plus the test suite, and note the substitution in the report.

Running tests may regenerate build artifacts (compiled SQL, dbt `target/`,
bundler output). If any are TRACKED, the tree is dirty afterwards with
machine-generated diffs, often polluted with ephemeral test values. Do NOT
commit them. Report them and suggest ignoring the artifact directories.

## Cleanup

```bash
# Plain `git worktree remove`, never --force: plain remove refuses while a
# worktree still has modified or untracked files, which is the signal to
# inspect and copy out anything that matters (an uncollected plan, an
# uncommitted fix). --force deletes those files unrecoverably.
for dir in "$WORKTREE_BASE"/*; do
  git worktree remove "$dir" \
    || echo "warning: $dir not removable: inspect its leftover files, collect what matters, then retry"
done

# rmdir refuses a non-empty directory; a failure means something survived.
rmdir "$WORKTREE_BASE" || echo "warning: $WORKTREE_BASE not empty: inspect before deleting"

# -d suffices: janitor/* branches were merged --no-ff or carry no commits.
# A -d refusal means unmerged commits nobody merged: report it, never -D.
# xargs -r (skip empty input) is a GNU extension; modern BSD/macOS xargs
# accepts it as a no-op.
git branch --list 'janitor/*' --format='%(refname:short)' | xargs -r git branch -d

rm .janitor/run.json
```

## Error recovery

### Working tree is dirty

STOP and report. Do NOT run `git stash`, `git reset`, `git restore`, or
`git checkout -- <path>` to clear it: uncommitted tracked changes
overwritten by those commands are unrecoverable. The user decides whether to
commit the work (explicit file paths) or abort the run.

### Leftovers from an earlier run

Report them with the recovery block from Preflight. A run that crashed mid
way is continued with `--resume`, never restarted over the top of its
branches.

### A worker fails

1. Record `failed` and the worker's last report in `run.json`
2. Check its worktree for partial work; commit anything complete by explicit
   path, or leave the branch unmerged and say so
3. Continue with the other branches; the failure goes in the final report

### A merge fails completely

```bash
git merge --abort
git cherry-pick <commit-sha>   # pick the branch's commits one by one instead
```

Do NOT fall back to `git rebase`: it rewrites history and destroys
uncommitted tracked changes without prompting. If cherry-picking also fails,
leave the branch unmerged, record it, and report the state.
