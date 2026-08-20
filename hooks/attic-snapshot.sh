#!/usr/bin/env bash
# Claude Code PreToolUse adapter for Write|Edit|NotebookEdit.
#
# Reads the tool payload on stdin, pulls out the target path, and snapshots
# that file BEFORE the tool changes it.
#
# This hook never blocks a write and never reports failure into the session.
# It either preserves the previous version or gets out of the way, because a
# backup mechanism that can break the thing it protects is worse than none.
#
# Install: see README.md. Requires jq.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAP="${ATTIC_SNAP_BIN:-$HERE/../bin/attic-snap}"

# jq is a hard dependency and its absence is silent by design elsewhere, so
# say something once, to stderr, rather than failing invisibly forever.
if ! command -v jq >/dev/null 2>&1; then
  echo "attic-snapshot: jq not found; no snapshots will be taken" >&2
  exit 0
fi

input="$(cat)"
f="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)"

[ -z "$f" ] && exit 0
[ -f "$f" ] || exit 0          # brand-new file: there is no previous version

"$SNAP" "$f" >/dev/null 2>&1 || true
exit 0
