#!/usr/bin/env bash
# Test suite for attic-snap and the two hooks.
#
#   tests/test-attic.sh
#
# Every test runs inside a throwaway root under .testtmp/, so the suite never
# touches a real .attic store and is safe to run anywhere. It cleans up after
# itself and leaves no state behind.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SNAP="$REPO/bin/attic-snap"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

# Each test gets a clean root under the repo rather than the system temp dir.
# Two reasons, both learned the hard way: attic-snap deliberately skips
# /tmp and /var/folders, so a root there stores nothing; and on macOS /var is
# a symlink to /private/var, so $(pwd) inside the root never equals the path
# mktemp handed back. Both make every assertion fail for the wrong reason.
TESTTMP="$REPO/.testtmp"
new_root() {
  mkdir -p "$TESTTMP"
  local d; d=$(mktemp -d "$TESTTMP/root.XXXXXX")
  d=$(cd "$d" && pwd)          # normalise before anything compares against it
  touch "$d/.attic-root"
  printf '%s' "$d"
}

echo "attic-snap tests"

# --- root resolution ----------------------------------------------------
R=$(new_root)
check "resolves root from .attic-root marker" "$(cd "$R" && "$SNAP" --root)" "$R"
check "ATTIC_ROOT overrides discovery" "$(ATTIC_ROOT="$R" "$SNAP" --root)" "$R"
(cd "$R" && mkdir -p a/b/c && cd a/b/c && [ "$("$SNAP" --root)" = "$R" ]) \
  && ok "finds root from a nested subdirectory" || bad "finds root from a nested subdirectory"

# --- snapshot basics ----------------------------------------------------
R=$(new_root); cd "$R"
printf 'version one\n' > doc.md
"$SNAP" doc.md >/dev/null
n=$(find .attic/doc.md -type f 2>/dev/null | wc -l | tr -d ' ')
check "stores one version on first snapshot" "$n" "1"

"$SNAP" doc.md >/dev/null
n=$(find .attic/doc.md -type f | wc -l | tr -d ' ')
check "re-snapshotting identical bytes is a no-op" "$n" "1"

printf 'version two\n' > doc.md
"$SNAP" doc.md >/dev/null
n=$(find .attic/doc.md -type f | wc -l | tr -d ' ')
check "stores a second version when content changes" "$n" "2"

# The stored copy must be the OLD bytes, which is the whole point.
stored=$(find .attic/doc.md -type f | sort | head -1)
check "stored copy holds the previous content" "$(cat "$stored")" "version one"

# --- filename shape -----------------------------------------------------
base=$(basename "$stored")
echo "$base" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z\.[0-9a-f]{8}\.md$' \
  && ok "version filename is <UTC>.<hash8>.<ext>" || bad "version filename shape" "$base"

# --- missing and odd inputs --------------------------------------------
"$SNAP" nonexistent.md >/dev/null 2>&1
check "missing file is not an error" "$?" "0"

printf 'x\n' > "file with spaces.md"
"$SNAP" "file with spaces.md" >/dev/null 2>&1
[ -d ".attic/file with spaces.md" ] && ok "handles spaces in filenames" || bad "handles spaces in filenames"

mkdir -p "sub dir"; printf 'y\n' > "sub dir/nested file.md"
"$SNAP" "sub dir/nested file.md" >/dev/null 2>&1
[ -d ".attic/sub dir/nested file.md" ] && ok "mirrors nested paths with spaces" || bad "mirrors nested paths with spaces"

# --- exclusions ---------------------------------------------------------
mkdir -p node_modules && printf 'dep\n' > node_modules/pkg.js
"$SNAP" node_modules/pkg.js >/dev/null 2>&1
[ ! -d ".attic/node_modules" ] && ok "skips node_modules" || bad "skips node_modules"

"$SNAP" .attic/doc.md/"$base" >/dev/null 2>&1
n=$(find .attic -name "*.$(basename "$base" | cut -d. -f2)*" -path "*attic/.attic*" 2>/dev/null | wc -l | tr -d ' ')
check "never snapshots the store itself" "$n" "0"

printf 'big\n' > big.bin
ATTIC_MAX_BYTES=2 "$SNAP" big.bin >/dev/null 2>&1
[ ! -d ".attic/big.bin" ] && ok "respects ATTIC_MAX_BYTES" || bad "respects ATTIC_MAX_BYTES"

ATTIC_EXCLUDE='*/secret/*' bash -c "mkdir -p secret && printf 's\n' > secret/k.txt && '$SNAP' secret/k.txt" >/dev/null 2>&1
[ ! -d ".attic/secret" ] && ok "respects ATTIC_EXCLUDE" || bad "respects ATTIC_EXCLUDE"

# --- list and restore ---------------------------------------------------
out=$("$SNAP" --list doc.md)
check "--list shows both versions" "$(echo "$out" | wc -l | tr -d ' ')" "2"
check "--list on an unknown file says so" "$("$SNAP" --list never.md)" "no versions stored for never.md"

# The safety property is that restoring can never destroy the file it
# replaces. Testing it needs content the store has not already seen: with
# "version two" already stored, the pre-restore snapshot is a correct dedupe
# no-op and the count would not move, which says nothing either way.
printf 'version three, never stored\n' > doc.md
"$SNAP" --restore "$stored" doc.md >/dev/null
check "--restore brings back the old content" "$(cat doc.md)" "version one"
grep -rq 'version three, never stored' .attic/doc.md \
  && ok "--restore preserves the file it overwrites" \
  || bad "--restore preserves the file it overwrites" "the replaced content is not in the store"

"$SNAP" --restore missing-version doc.md >/dev/null 2>&1
check "--restore on a missing version fails loudly" "$?" "1"

# --- external files -----------------------------------------------------
# Outside the root, but not inside an excluded temp path.
EXTHOME="$TESTTMP/external-$$"; mkdir -p "$EXTHOME"; printf 'outside\n' > "$EXTHOME/o.md"
(cd "$R" && "$SNAP" "$EXTHOME/o.md" >/dev/null 2>&1)
find "$R/.attic/_external" -name '*.md' 2>/dev/null | grep -q . \
  && ok "files outside the root land under _external/" || bad "files outside the root land under _external/"
rm -rf "$EXTHOME"

# --- hooks --------------------------------------------------------------
echo
echo "hook tests"
if command -v jq >/dev/null 2>&1; then
  R2=$(new_root); cd "$R2"; printf 'hook v1\n' > h.md
  printf '{"tool_input":{"file_path":"%s/h.md"}}' "$R2" | \
    ATTIC_SNAP_BIN="$SNAP" ATTIC_ROOT="$R2" bash "$REPO/hooks/attic-snapshot.sh" >/dev/null 2>&1
  [ -d "$R2/.attic/h.md" ] && ok "snapshot hook stores the target" || bad "snapshot hook stores the target"

  printf '{"tool_input":{}}' | ATTIC_SNAP_BIN="$SNAP" bash "$REPO/hooks/attic-snapshot.sh" >/dev/null 2>&1
  check "snapshot hook tolerates an empty payload" "$?" "0"

  printf 'not json' | ATTIC_SNAP_BIN="$SNAP" bash "$REPO/hooks/attic-snapshot.sh" >/dev/null 2>&1
  check "snapshot hook tolerates malformed input" "$?" "0"

  CONF=$(mktemp "${TMPDIR:-/tmp}/attic-conf.XXXXXX")
  printf '# comment\n\n*/audit-logs/*  Records, not drafts.\n' > "$CONF"
  out=$(printf '{"tool_input":{"file_path":"/x/audit-logs/y.md"}}' | ATTIC_CONF="$CONF" bash "$REPO/hooks/immutable-zone-guard.sh")
  echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    && ok "zone guard denies a configured path" || bad "zone guard denies a configured path" "$out"
  echo "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'Records, not drafts.' \
    && ok "zone guard returns the configured reason" || bad "zone guard returns the configured reason"

  out=$(printf '{"tool_input":{"file_path":"/x/working/y.md"}}' | ATTIC_CONF="$CONF" bash "$REPO/hooks/immutable-zone-guard.sh")
  check "zone guard allows an unlisted path" "$out" ""

  out=$(printf '{"tool_input":{"file_path":"/x/audit-logs/y.md"}}' | ATTIC_CONF=/nonexistent bash "$REPO/hooks/immutable-zone-guard.sh")
  check "zone guard denies nothing without a config" "$out" ""

  # Security regression: a case-insensitive filesystem makes /x/AUDIT-LOGS/y.md
  # and /x/audit-logs/y.md the same file, so a case-sensitive guard denies one
  # and waves the other through. Found by an adversarial pass, not by design.
  out=$(printf '{"tool_input":{"file_path":"/x/AUDIT-LOGS/y.md"}}' | ATTIC_CONF="$CONF" bash "$REPO/hooks/immutable-zone-guard.sh")
  echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    && ok "zone guard is not bypassed by changing case" \
    || bad "zone guard is not bypassed by changing case" "$out"

  out=$(printf '{"tool_input":{"file_path":"/x/Audit-Logs/Y.MD"}}' | ATTIC_CONF="$CONF" bash "$REPO/hooks/immutable-zone-guard.sh")
  echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    && ok "zone guard matches mixed case in path and extension" \
    || bad "zone guard matches mixed case in path and extension" "$out"
  rm -f "$CONF"
else
  echo "  skip  hook tests (jq not installed)"
fi

cd /; rm -rf "$TESTTMP" 2>/dev/null
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
