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
# See attic.conf.example. Without a config, this guard denies nothing; with
# rules configured but jq missing, it blocks writes rather than failing open.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${ATTIC_CONF:-$HERE/../attic.conf}"

# Without jq the payload cannot be parsed, so zones cannot be told apart
# from working files. If rules are configured, fail closed: exit 2 blocks
# the tool call and surfaces the message. A silently disabled guard is the
# one failure mode this file must never have. With nothing configured there
# is nothing to enforce, and staying quiet is correct.
if ! command -v jq >/dev/null 2>&1; then
  if [ -f "$CONF" ] && grep -Eq '^[[:space:]]*[^#[:space:]]' "$CONF"; then
    echo "immutable-zone-guard: jq is not installed, so the zone rules in $CONF cannot be enforced. Blocking this write: install jq, or remove the config to disable the guard." >&2
    exit 2
  fi
  exit 0
fi

# Match zone patterns case-insensitively.
#
# This is a security property, not a convenience. macOS and Windows default to
# case-insensitive filesystems, so /work/Records/f.md and /work/records/f.md are
# the same file; a case-sensitive guard denies one and waves the other straight
# through. On a case-sensitive filesystem this errs toward denying a path that
# merely looks like a protected one, which is the right direction to err: a
# false deny costs one config edit, a false allow costs the record.
shopt -s nocasematch 2>/dev/null || true

deny() {
  jq -nc --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}

input="$(cat)"
f="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)"
[ -z "$f" ] && exit 0
[ -f "$CONF" ] || exit 0

# Match the canonical path as well as the literal one. The literal string is
# what an agent controls: a symlink alias created in an unguarded directory,
# a symlinked parent, or a relative path all reach the same record while
# looking like neither zone. The raw path is still matched too, so
# canonicalizing can only widen what is denied, never narrow it.
canon="$f"
case "$canon" in /*) ;; *) canon="$PWD/$canon" ;; esac
if resolved=$(readlink -f -- "$canon" 2>/dev/null) && [ -n "$resolved" ]; then
  canon="$resolved"
else
  # readlink -f needs the path to mostly exist; for a file not created yet,
  # resolve just the directory and keep the basename.
  pd=$(cd -P -- "$(dirname -- "$canon")" 2>/dev/null && pwd) && canon="$pd/$(basename -- "$canon")"
fi

# Config format, one rule per line:  <glob><TAB or spaces><reason>
# Lines starting with # and blank lines are ignored.
while IFS= read -r line || [ -n "$line" ]; do
  # Strip leading whitespace before anything else. Without this, an indented
  # rule parsed to an empty pattern and was skipped silently, so a guard that
  # looked configured enforced nothing. A rule that does not load must never
  # fail quietly.
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"     # and trailing, including \r
  case "$line" in ''|'#'*) continue ;; esac
  pattern="${line%%[[:space:]]*}"
  reason="${line#"$pattern"}"
  reason="${reason#"${reason%%[![:space:]]*}"}"     # strip leading whitespace
  [ -z "$pattern" ] && continue
  msg="${reason:-Immutable zone: $pattern holds records, not working files. Nothing here is edited after the fact.}"
  # shellcheck disable=SC2254
  case "$f" in $pattern) deny "$msg" ;; esac
  # shellcheck disable=SC2254
  case "$canon" in $pattern) deny "$msg" ;; esac
done < "$CONF"

exit 0
