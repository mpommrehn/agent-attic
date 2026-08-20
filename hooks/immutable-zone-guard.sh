#!/usr/bin/env bash
# Claude Code PreToolUse guard for Write|Edit|NotebookEdit.
#
# Hard-denies edits to paths that hold records rather than working files.
#
# The distinction this enforces: a working file is something you change, and a
# record is something whose value depends on it NOT having changed after the
# fact. A signed contract, an invoice as sent, a filed report, an audit log, a
# document exactly as it went to a customer. If an agent can quietly edit one,
# it proves nothing, and proving something is the entire reason it is kept.
#
# Zones are read from attic.conf so the list is yours, not the tool's.
# See attic.conf.example. Without a config, this guard denies nothing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${ATTIC_CONF:-$HERE/../attic.conf}"

command -v jq >/dev/null 2>&1 || exit 0

deny() {
  jq -nc --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}

input="$(cat)"
f="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)"
[ -z "$f" ] && exit 0
[ -f "$CONF" ] || exit 0

# Config format, one rule per line:  <glob><TAB or spaces><reason>
# Lines starting with # and blank lines are ignored.
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  pattern="${line%%[[:space:]]*}"
  reason="${line#"$pattern"}"
  reason="${reason#"${reason%%[![:space:]]*}"}"     # strip leading whitespace
  [ -z "$pattern" ] && continue
  # shellcheck disable=SC2254
  case "$f" in
    $pattern) deny "${reason:-Immutable zone: $pattern holds records, not working files. Nothing here is edited after the fact.}" ;;
  esac
done < "$CONF"

exit 0
