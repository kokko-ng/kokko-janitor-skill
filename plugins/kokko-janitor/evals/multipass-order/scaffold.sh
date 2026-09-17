#!/usr/bin/env bash
# Builds the throwaway repo the case runs in. The eval harness runs this in
# the fresh workspace directory with a temporary HOME, so the git identity
# set here never touches the real user's config.
set -euo pipefail
git config --global user.email "eval@example.com"
git config --global user.name "eval"
git config --global init.defaultBranch main
git init -q .
mkdir -p prompts
cat > prompts/a.md <<'PROMPT'
Append exactly one line containing the single letter `A` to the file
`passes.log` in the repository root (create the file if it does not exist).
Do nothing else: no other file changes, no git commands.
Report the file's contents when done.
PROMPT
cat > prompts/b.md <<'PROMPT'
Append exactly one line containing the single letter `B` to the file
`passes.log` in the repository root (create the file if it does not exist).
Do nothing else: no other file changes, no git commands.
Report the file's contents when done.
PROMPT
printf 'passes.log\n' > .gitignore
git add -- prompts/a.md prompts/b.md .gitignore
git commit -q -m "chore: eval fixture"
