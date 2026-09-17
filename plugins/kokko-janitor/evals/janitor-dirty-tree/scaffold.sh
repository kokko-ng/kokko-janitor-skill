#!/usr/bin/env bash
# A committed Python project with one uncommitted edit: the janitor must
# stop at preflight and leave the edit alone.
set -euo pipefail
git config --global user.email "eval@example.com"
git config --global user.name "eval"
git config --global init.defaultBranch main
git init -q .
mkdir -p src
cat > pyproject.toml <<'TOML'
[project]
name = "fixture"
version = "0.1.0"
requires-python = ">=3.11"
TOML
cat > src/app.py <<'PY'
def add(a: int, b: int) -> int:
    return a + b
PY
git add -- pyproject.toml src/app.py
git commit -q -m "chore: eval fixture"
printf '\n\ndef sub(a: int, b: int) -> int:\n    return a - b\n' >> src/app.py
