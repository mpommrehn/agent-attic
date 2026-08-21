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
  d=$(cd "$d" && pwd)          # normalize before anything compares against it
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
R=$(new_root); cd "$R" || exit 1
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

# One unreadable file must not cost the rest of the batch its protection:
# report it, keep going, exit nonzero at the end. Found by review 2026-08-21.
printf 'a\n' > locked.txt && printf 'b\n' > after.txt
chmod 000 locked.txt
err=$("$SNAP" locked.txt after.txt 2>&1 >/dev/null)
rc=$?
check "an unreadable file makes the batch exit nonzero" "$rc" "1"
echo "$err" | grep -q 'cannot read' \
  && ok "the unreadable file is reported by name" \
  || bad "the unreadable file is reported by name" "$err"
[ -d .attic/after.txt ] \
  && ok "files after an unreadable one are still snapshotted" \
  || bad "files after an unreadable one are still snapshotted"
chmod 644 locked.txt

# Usage exits: -h is a request, a bare invocation is a usage error, and
# neither is a shell error. exit "${1:+0}" used to expand to exit "" and 255.
"$SNAP" -h >/dev/null 2>&1
check "-h exits 0" "$?" "0"
"$SNAP" >/dev/null 2>&1
check "no arguments prints usage and exits 1" "$?" "1"
err=$("$SNAP" 2>&1 >/dev/null)
check "no-argument usage puts nothing on stderr" "$err" ""

# Usage text runs to the end of the header comment and no further, however
# long the header is: the old hard-coded sed line ranges went stale the
# moment the header was edited.
"$SNAP" -h | grep -q 'what it does not do' \
  && ok "attic-snap usage reaches the end of its header" \
  || bad "attic-snap usage reaches the end of its header"
"$SNAP" -h | grep -q 'set -' \
  && bad "attic-snap usage stops at the header" \
  || ok "attic-snap usage stops at the header"

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

# A skipped explicit target must say so: exit 0 with no output reads as
# protection the caller does not have. Found by review 2026-08-21. Sweeps
# (attic-run --dir) set ATTIC_SWEEP to keep exclusions quiet, since dropping
# excluded trees silently is what a sweep is for.
err=$("$SNAP" node_modules/pkg.js 2>&1 >/dev/null)
echo "$err" | grep -q 'skipped (excluded path)' \
  && ok "an excluded target says it was skipped" \
  || bad "an excluded target says it was skipped" "$err"
err=$(ATTIC_SWEEP=1 "$SNAP" node_modules/pkg.js 2>&1 >/dev/null)
check "ATTIC_SWEEP keeps exclusion skips quiet" "$err" ""

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

# A restore must refuse to proceed when it cannot preserve the file it is
# about to overwrite. The pre-restore snapshot can be silently skipped (size
# cap, exclusion), and quietly overwriting anyway is exactly the data loss
# the README promises cannot happen. Found by review 2026-08-21.
printf 'small\n' > guard.txt
"$SNAP" guard.txt >/dev/null
gstored=$(find .attic/guard.txt -type f | head -1)
printf 'newer and bigger\n' > guard.txt
ATTIC_MAX_BYTES=5 "$SNAP" --restore "$gstored" guard.txt >/dev/null 2>&1
check "--restore refuses when the target is over the size cap" "$?" "1"
check "the oversize target survives the refused restore" "$(cat guard.txt)" "newer and bigger"

printf 'excluded newer\n' > guard.txt
ATTIC_EXCLUDE='*/guard.txt' "$SNAP" --restore "$gstored" guard.txt >/dev/null 2>&1
check "--restore refuses when the target matches an exclusion" "$?" "1"
check "the excluded target survives the refused restore" "$(cat guard.txt)" "excluded newer"

"$SNAP" --restore "$gstored" fresh-copy.txt >/dev/null 2>&1
check "--restore into a target that does not exist still works" "$(cat fresh-copy.txt 2>/dev/null)" "small"

# Recovery case: the parent tree was deleted but the store still has the
# file. abs_path used to mangle the path when cd failed, so --list looked in
# _external/ and found nothing. Found by review 2026-08-21.
mkdir -p src && printf 'keep\n' > src/notes.md
"$SNAP" src/notes.md >/dev/null
rm -rf src
"$SNAP" --list src/notes.md | grep -Eq '^[0-9]{4}-.*\.[0-9a-f]{8}\.md$' \
  && ok "--list finds versions after the parent directory was deleted" \
  || bad "--list finds versions after the parent directory was deleted" "$("$SNAP" --list src/notes.md)"
sv=$(find .attic/src/notes.md -type f 2>/dev/null | head -1)
"$SNAP" --restore "$sv" src/notes.md >/dev/null 2>&1
check "--restore recreates a deleted parent directory" "$(cat src/notes.md 2>/dev/null)" "keep"

# A zero-byte state is nothing to preserve: storing it violates the store's
# no-empty-versions invariant (see tests/test-adversarial.sh), and restoring
# it would only ever recreate an empty file. The check is on the copied
# bytes, so a file truncated mid-snapshot is discarded too.
: > hollow.txt
"$SNAP" hollow.txt >/dev/null 2>&1
rc=$?
[ "$rc" = "0" ] && [ ! -d .attic/hollow.txt ] \
  && ok "an empty file is not stored" \
  || bad "an empty file is not stored" "exit $rc, stored: $(find .attic/hollow.txt -type f 2>/dev/null | wc -l | tr -d ' ')"

# And an empty target is nothing a restore can destroy, so it must not be
# refused for lacking a stored version.
"$SNAP" --restore "$gstored" hollow.txt >/dev/null 2>&1
check "--restore over an empty target proceeds" "$(cat hollow.txt 2>/dev/null)" "small"

# The stored name must always match the stored bytes. A file rewritten
# between hash and copy used to be stored under the old hash, and dedupe
# then refused to ever store the old bytes again. The cp shim rewrites the
# source mid-snapshot to force the race deterministically.
printf 'content A\n' > race.txt
RSTUB=$(mktemp -d "$TESTTMP/race.XXXXXX")
cat > "$RSTUB/cp" <<SHIM
#!/bin/bash
printf 'content B\n' > "$PWD/race.txt"
exec /bin/cp "\$@"
SHIM
chmod +x "$RSTUB/cp"
PATH="$RSTUB:$PATH" "$SNAP" race.txt >/dev/null 2>&1
stored_race=$(find .attic/race.txt -type f | head -1)
name_hash=$(basename "$stored_race" | cut -d. -f2)
data_hash=$( (shasum -a 1 "$stored_race" 2>/dev/null || sha1sum "$stored_race") | cut -c1-8)
check "a mid-snapshot rewrite is stored under its own hash" "$data_hash" "$name_hash"
printf 'content A\n' > race.txt
"$SNAP" race.txt >/dev/null 2>&1
grep -rq 'content A' .attic/race.txt \
  && ok "the pre-rewrite content can still be stored afterwards" \
  || bad "the pre-rewrite content can still be stored afterwards" "dedupe poisoned by the wrong-hash version"
rm -rf "$RSTUB"

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
  R2=$(new_root); cd "$R2" || exit 1; printf 'hook v1\n' > h.md
  printf '{"tool_input":{"file_path":"%s/h.md"}}' "$R2" | \
    ATTIC_SNAP_BIN="$SNAP" ATTIC_ROOT="$R2" bash "$REPO/hooks/attic-snapshot.sh" >/dev/null 2>&1
  [ -d "$R2/.attic/h.md" ] && ok "snapshot hook stores the target" || bad "snapshot hook stores the target"

  printf '{"tool_input":{}}' | ATTIC_SNAP_BIN="$SNAP" bash "$REPO/hooks/attic-snapshot.sh" >/dev/null 2>&1
  check "snapshot hook tolerates an empty payload" "$?" "0"

  printf 'not json' | ATTIC_SNAP_BIN="$SNAP" bash "$REPO/hooks/attic-snapshot.sh" >/dev/null 2>&1
  check "snapshot hook tolerates malformed input" "$?" "0"

  # The snapshot hook fails closed (2026-08-21): when the snapshot cannot be
  # taken, the write is denied with the reason, instead of proceeding
  # silently unprotected while the hook looks installed.
  printf 'hook v2\n' > "$R2/h2.md"
  out=$(printf '{"tool_input":{"file_path":"%s/h2.md"}}' "$R2" | \
    ATTIC_SNAP_BIN=/nonexistent-attic-snap ATTIC_ROOT="$R2" bash "$REPO/hooks/attic-snapshot.sh")
  echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    && ok "snapshot hook denies the write when the snapshot fails" \
    || bad "snapshot hook denies the write when the snapshot fails" "$out"
  echo "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null | grep -q 'h2.md' \
    && ok "the snapshot-hook denial names the file" \
    || bad "the snapshot-hook denial names the file" "$out"

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

  # Security regressions from a 2026-08-21 review: the guard matched only the
  # literal payload string, so a symlink alias created in an unguarded
  # directory, a symlinked directory, or a relative path reached the record
  # without a deny.
  mkdir -p "$R2/audit-logs" "$R2/drafts"
  printf 'record\n' > "$R2/audit-logs/real.md"
  ln -s "$R2/audit-logs/real.md" "$R2/drafts/alias.md"
  out=$(printf '{"tool_input":{"file_path":"%s/drafts/alias.md"}}' "$R2" | ATTIC_CONF="$CONF" bash "$REPO/hooks/immutable-zone-guard.sh")
  echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    && ok "zone guard is not bypassed by a symlink alias" \
    || bad "zone guard is not bypassed by a symlink alias" "$out"

  ln -s "$R2/audit-logs" "$R2/dirlink"
  out=$(printf '{"tool_input":{"file_path":"%s/dirlink/real.md"}}' "$R2" | ATTIC_CONF="$CONF" bash "$REPO/hooks/immutable-zone-guard.sh")
  echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    && ok "zone guard is not bypassed by a symlinked directory" \
    || bad "zone guard is not bypassed by a symlinked directory" "$out"

  out=$(cd "$R2" && printf '{"tool_input":{"file_path":"audit-logs/real.md"}}' | ATTIC_CONF="$CONF" bash "$REPO/hooks/immutable-zone-guard.sh")
  echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    && ok "zone guard is not bypassed by a relative path" \
    || bad "zone guard is not bypassed by a relative path" "$out"

  # Without jq the guard cannot parse the payload. With rules configured it
  # must fail closed (exit 2 blocks the tool call) and say why on stderr;
  # silently allowing everything is the one failure mode it must never have.
  STUB=$(mktemp -d "$TESTTMP/stub.XXXXXX")
  for t in cat grep dirname basename readlink; do ln -s "$(command -v "$t")" "$STUB/$t"; done
  printf '{"tool_input":{"file_path":"/x/audit-logs/y.md"}}' | ATTIC_CONF="$CONF" PATH="$STUB" /bin/bash "$REPO/hooks/immutable-zone-guard.sh" >/dev/null 2>&1
  check "guard without jq blocks when rules are configured" "$?" "2"
  errout=$(printf '{"tool_input":{"file_path":"/x/audit-logs/y.md"}}' | ATTIC_CONF="$CONF" PATH="$STUB" /bin/bash "$REPO/hooks/immutable-zone-guard.sh" 2>&1 >/dev/null)
  echo "$errout" | grep -q jq && ok "guard without jq explains itself" || bad "guard without jq explains itself" "$errout"
  printf '{"tool_input":{"file_path":"/x/audit-logs/y.md"}}' | ATTIC_CONF=/nonexistent PATH="$STUB" /bin/bash "$REPO/hooks/immutable-zone-guard.sh" >/dev/null 2>&1
  check "guard without jq stays quiet when nothing is configured" "$?" "0"

  # The snapshot hook cannot work at all without jq, so it blocks too.
  printf 'hook v3\n' > "$R2/h3.md"
  printf '{"tool_input":{"file_path":"%s/h3.md"}}' "$R2" | \
    ATTIC_SNAP_BIN="$SNAP" PATH="$STUB" /bin/bash "$REPO/hooks/attic-snapshot.sh" >/dev/null 2>&1
  check "snapshot hook without jq blocks the write" "$?" "2"
  rm -rf "$STUB"
  rm -f "$CONF"
else
  echo "  skip  hook tests (jq not installed)"
fi

# --- attic-run ----------------------------------------------------------
echo
echo "attic-run tests"
RUN="$REPO/bin/attic-run"
R3=$(new_root); cd "$R3" || exit 1

printf 'original\n' > out.txt
"$RUN" out.txt -- sh -c 'printf regenerated > out.txt' >/dev/null 2>&1
check "runs the command" "$(cat out.txt)" "regenerated"
grep -rq 'original' .attic/out.txt 2>/dev/null \
  && ok "snapshots the target before the command runs" \
  || bad "snapshots the target before the command runs"

# The snapshot must survive a failing command; that is the whole point.
printf 'good content\n' > risky.txt
"$RUN" risky.txt -- sh -c 'printf broken > risky.txt; exit 3' >/dev/null 2>&1
check "propagates the command's exit status" "$?" "3"
grep -rq 'good content' .attic/risky.txt 2>/dev/null \
  && ok "snapshot survives a failing command" || bad "snapshot survives a failing command"

"$RUN" missing.txt -- true >/dev/null 2>&1
check "a missing target is not an error" "$?" "0"

# --dir
mkdir -p tree/sub && printf 'a\n' > tree/a.txt && printf 'b\n' > tree/sub/b.txt
"$RUN" --dir tree -- true >/dev/null 2>&1
[ -d .attic/tree/a.txt ] && [ -d .attic/tree/sub/b.txt ] \
  && ok "--dir snapshots the whole tree" || bad "--dir snapshots the whole tree"

mkdir -p tree/node_modules && printf 'dep\n' > tree/node_modules/x.js
"$RUN" --dir tree -- true >/dev/null 2>&1
[ ! -d .attic/tree/node_modules ] && ok "--dir honors exclusions" || bad "--dir honors exclusions"

# --dir must protect files reached through symlinks: the wrapped command
# writes through the link and rewrites the target. Found by review 2026-08-21.
mkdir -p realdir linktree && printf 'real\n' > realdir/lf.txt
ln -s "$PWD/realdir/lf.txt" linktree/link.txt
"$RUN" --dir linktree -- true >/dev/null 2>&1
[ -d .attic/realdir/lf.txt ] && ok "--dir follows symlinks to files" || bad "--dir follows symlinks to files"

err=$("$RUN" --dir tree -- true 2>&1 >/dev/null)
echo "$err" | grep -q 'excluded path' \
  && bad "--dir sweeps stay quiet about exclusions" "$err" \
  || ok "--dir sweeps stay quiet about exclusions"

# Argument handling
"$RUN" -h >/dev/null 2>&1
check "attic-run -h exits 0" "$?" "0"
"$RUN" -h | grep -q 'pipeline' \
  && ok "attic-run usage reaches the end of its header" \
  || bad "attic-run usage reaches the end of its header"
"$RUN" -h | grep -q 'set -' \
  && bad "attic-run usage stops at the header" \
  || ok "attic-run usage stops at the header"
"$RUN" out.txt echo hi >/dev/null 2>&1
check "missing -- is rejected" "$?" "2"
"$RUN" out.txt -- >/dev/null 2>&1
check "empty command is rejected" "$?" "2"
"$RUN" --dir nonexistent -- true >/dev/null 2>&1
check "a missing --dir is rejected" "$?" "2"

# If snapshotting fails, the command must not run at all: "snapshots happen
# first" is only a guarantee if a failed snapshot blocks the destructive
# step. Found by review 2026-08-21.
printf 'vital\n' > vital.txt
ATTIC_SNAP_BIN=/nonexistent-attic-snap "$RUN" vital.txt -- sh -c 'printf clobbered > vital.txt' >/dev/null 2>&1
check "refuses to run when the snapshot tool fails" "$?" "2"
check "the target survives the refused run" "$(cat vital.txt)" "vital"

ATTIC_SNAP_BIN=/nonexistent-attic-snap "$RUN" --dir tree -- sh -c 'printf x > tree/a.txt' >/dev/null 2>&1
check "--dir refuses to run when the snapshot tool fails" "$?" "2"
check "--dir targets survive the refused run" "$(cat tree/a.txt)" "a"

NOROOT=$(mktemp -d "${TMPDIR:-/tmp}/attic-noroot.XXXXXX")
printf 'orig\n' > "$NOROOT/f.txt"
(cd "$NOROOT" && "$RUN" f.txt -- sh -c 'printf gone > f.txt') >/dev/null 2>&1
check "refuses to run when no working root exists" "$?" "2"
check "the rootless target is untouched" "$(cat "$NOROOT/f.txt")" "orig"
rm -rf "$NOROOT"

# Arguments must reach the command untouched.
out=$("$RUN" out.txt -- printf '%s|%s' 'two words' 'x*y')
check "command arguments are passed verbatim" "$out" "two words|x*y"

printf 'v1\n' > "spaced name.txt"
"$RUN" "spaced name.txt" -- true >/dev/null 2>&1
[ -d ".attic/spaced name.txt" ] && ok "handles a target with spaces" || bad "handles a target with spaces"

cd / || exit 1; rm -rf "$TESTTMP" 2>/dev/null
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
