#!/bin/bash
# progress-guard.sh - Stop / SubagentStop hook.
#
# The tailored validation prompts (kokko-validation's `tailor` skill) keep
# their state in prompts/<name>-progress.md, one line per item:
#
#     US-003 | pending / in-progress / passed / blocked | note
#     D-014  | open / fixed / blocked | page | viewport | note
#
# The prompts used to carry a "work persistently, do not stop" paragraph; it
# was weak and got removed. This hook is the mechanical replacement: when the
# agent tries to stop while a recently touched progress file still lists
# open items, the stop is blocked once with a reason naming the file and the
# count, and the agent keeps working.
#
# Loop breakers, so a genuinely stuck pass can still end:
#   - only files under prompts/ modified in the last KOKKO_PROGRESS_GUARD_MINUTES
#     (default 30) count; a stale file from last week never blocks anything
#   - a file blocks a stop only if its content changed since the last time it
#     blocked one: no progress between two stops means the pass is done
#   - `blocked` is a terminal state; the prompts' stuck rule flips items to it
#   - KOKKO_PROGRESS_GUARD=off disables the hook
#
# Output is either nothing (allow) or a single JSON decision on stdout.
# Everything else is silent: a hook that fails must fail open.
set -u

[ "${KOKKO_PROGRESS_GUARD:-on}" = "off" ] && exit 0

input=$(cat 2>/dev/null || true)
cwd=""
if command -v jq >/dev/null 2>&1; then
    cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
fi
[ -n "$cwd" ] && [ -d "$cwd" ] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"

[ -d "$cwd/prompts" ] || exit 0

minutes="${KOKKO_PROGRESS_GUARD_MINUTES:-30}"
state_dir="${TMPDIR:-/tmp}/kokko-progress-guard"
mkdir -p "$state_dir" 2>/dev/null || exit 0

blocks=""
while IFS= read -r file; do
    [ -n "$file" ] || continue
    open=$(grep -cE '^[[:space:]]*[A-Za-z]+-[0-9]+[[:space:]]*\|[[:space:]]*(pending|in-progress|open)[[:space:]]*\|' "$file" 2>/dev/null || true)
    [ "${open:-0}" -gt 0 ] || continue
    digest=$(cksum "$file" 2>/dev/null | cut -d' ' -f1-2)
    key=$(printf '%s' "$file" | cksum | cut -d' ' -f1)
    state="$state_dir/$key"
    if [ -f "$state" ] && [ "$(cat "$state" 2>/dev/null)" = "$digest" ]; then
        continue   # unchanged since the last block: do not loop
    fi
    printf '%s' "$digest" > "$state" 2>/dev/null || true
    rel="${file#"$cwd"/}"
    blocks="${blocks:+$blocks; }$rel still lists $open open item(s)"
done < <(find "$cwd/prompts" -maxdepth 1 -type f -name '*-progress.md' -mmin "-$minutes" 2>/dev/null | sort)

[ -n "$blocks" ] || exit 0

reason="Progress guard: $blocks. Keep working through the pending and in-progress items; mark one blocked only when the prompt's stuck rule applies. Set KOKKO_PROGRESS_GUARD=off to disable this hook."
if command -v jq >/dev/null 2>&1; then
    jq -cn --arg r "$reason" '{decision: "block", reason: $r}'
else
    escaped=${reason//\\/\\\\}
    escaped=${escaped//\"/\\\"}
    printf '{"decision":"block","reason":"%s"}\n' "$escaped"
fi
exit 0
