#!/usr/bin/env bash
# Claude Code PreToolUse adapter for Write|Edit|NotebookEdit.
#
# Reads the tool payload on stdin, pulls out the target path, and snapshots
# that file BEFORE the tool changes it.
#
# This hook fails closed. If the snapshot cannot be taken, the write is
# denied and the reason says why: a protection layer that fails silently
# leaves every edit unprotected while looking installed, which is worse
# than an honest refusal. A brand-new file passes through untouched, and a
# skip that is policy (exclusions, the size cap) is a success, not a
# failure.
#
# Install: see README.md. Requires jq.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAP="${ATTIC_SNAP_BIN:-$HERE/../bin/attic-snap}"

# Without jq the payload cannot be parsed, so no snapshot can ever be
# taken. Exit 2 blocks the tool call and surfaces the message.
if ! command -v jq >/dev/null 2>&1; then
  echo "attic-snapshot: jq is not installed, so no snapshot can be taken. Blocking the write: install jq, or remove this hook." >&2
  exit 2
fi

input="$(cat)"
f="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)"

[ -z "$f" ] && exit 0
[ -f "$f" ] || exit 0          # brand-new file: there is no previous version

if ! err=$("$SNAP" "$f" 2>&1 >/dev/null); then
  err="${err%%$'\n'*}"
  jq -nc --arg reason "attic-snapshot: could not snapshot $f (${err:-unknown error}). Blocking the write so the previous version is not lost: fix the attic setup, or remove this hook." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
fi
exit 0
