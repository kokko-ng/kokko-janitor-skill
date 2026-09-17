#!/usr/bin/env bash
# Verify every skill and agent this plugin cites by namespaced name exists.
#
# The janitor drives kokko-code-quality's check skills by their namespaced
# names (`/kokko-code-quality:security`), and nothing else ties the two
# repositories together: a renamed check in kokko-skills would break every
# janitor run without any test noticing. This script resolves each citation
# against a kokko-skills checkout (CI clones one next to this repo) and
# against this repo's own skills and agents.
#
# Usage: bash scripts/check-cross-repo-refs.sh [path-to-kokko-skills]
#        (default: $KOKKO_SKILLS_DIR, else ../kokko-skills)
set -euo pipefail

SKILLS_DIR="${1:-${KOKKO_SKILLS_DIR:-../kokko-skills}}"
if [ ! -d "$SKILLS_DIR/plugins" ]; then
  echo "ERROR: kokko-skills checkout not found at $SKILLS_DIR (pass the path or set KOKKO_SKILLS_DIR)"
  exit 2
fi

FAIL=0
count=0

# Namespaced citations: `/plugin:skill` for skills, `plugin:name` without the
# slash for agents (which may also be a skill name). Placeholders such as
# `/kokko-code-quality:<check>` never match the character class.
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  count=$((count + 1))
  bare="${ref#/}"
  plugin="${bare%%:*}"
  name="${bare##*:}"
  case "$plugin" in
    kokko-janitor) base="." ;;
    *) base="$SKILLS_DIR" ;;
  esac
  skill="$base/plugins/$plugin/skills/$name/SKILL.md"
  agent="$base/plugins/$plugin/agents/$name.md"
  case "$ref" in
    /*)
      [ -f "$skill" ] || { echo "ERROR: $ref is cited but $skill does not exist"; FAIL=1; }
      ;;
    *)
      if [ ! -f "$agent" ] && [ ! -f "$skill" ]; then
        echo "ERROR: $ref is cited but neither $agent nor $skill exists"
        FAIL=1
      fi
      ;;
  esac
done < <(grep -rhoE '/?kokko-[a-z-]+:[a-z0-9-]+' plugins/ README.md | sort -u)

if [ "$FAIL" -eq 0 ]; then
  echo "cross-repo references: all $count namespaced citations resolve"
fi
exit "$FAIL"
