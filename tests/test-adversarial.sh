#!/usr/bin/env bash
# Adversarial probes for attic-snap, attic-run, and the hooks.
#
#   tests/test-adversarial.sh
#
# Separate from test-attic.sh on purpose. That suite asserts the tool does what
# it claims. This one attacks the claims: races, symlink games, malformed
# config, concurrency, and containment. Every probe here exists because the
# behavior was assumed rather than verified.
#
# A probe that passes is not proof of safety. It is one fewer way in.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SNAP="$REPO/bin/attic-snap"
RUN="$REPO/bin/attic-run"
TESTTMP="$REPO/.testtmp-adv"

PASS=0; FAIL=0; NOTE=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
note() { NOTE=$((NOTE+1)); printf '  note  %s\n' "$1"; }

new_root() {
  mkdir -p "$TESTTMP"
  local d; d=$(mktemp -d "$TESTTMP/root.XXXXXX"); d=$(cd "$d" && pwd)
  touch "$d/.attic-root"; printf '%s' "$d"
}

# Every stored version must be a faithful copy of something, never empty and
# never truncated. This is the invariant the whole tool rests on.
store_is_sane() {
  local root="$1" bad_files=0
  while IFS= read -r -d '' v; do
    [ -s "$v" ] || bad_files=$((bad_files+1))
  done < <(find "$root/.attic" -type f -print0 2>/dev/null)
  [ "$bad_files" -eq 0 ]
}

echo "=== 1. TOCTOU: the file changes between the test and the copy ==="
R=$(new_root); cd "$R" || exit 1
printf 'stable content\n' > racy.txt
# Hammer the file while snapshotting it. If snap_one's [ -f ] test and its cp
# can disagree, this is where a zero-byte or partial version shows up.
for i in $(seq 1 40); do
  ( printf 'rewritten %s\n' "$i" > racy.txt ) &
  ( "$SNAP" racy.txt >/dev/null 2>&1 ) &
done
wait
if store_is_sane "$R"; then ok "no empty or truncated versions under a write race"
else bad "no empty or truncated versions under a write race" "found a zero-byte version"; fi

# Same race, but the file disappears mid-flight.
printf 'here now\n' > vanishing.txt
for i in $(seq 1 30); do
  ( "$SNAP" vanishing.txt >/dev/null 2>&1 ) &
  ( rm -f vanishing.txt 2>/dev/null; printf 'back\n' > vanishing.txt ) &
done
wait
if store_is_sane "$R"; then ok "a file deleted mid-snapshot does not corrupt the store"
else bad "a file deleted mid-snapshot does not corrupt the store"; fi

echo
echo "=== 2. symlinks ==="
R=$(new_root); cd "$R" || exit 1
printf 'real target\n' > real.txt
ln -s real.txt link.txt
"$SNAP" link.txt >/dev/null 2>&1
if find .attic -type f -exec grep -lq 'real target' {} + 2>/dev/null; then
  ok "a symlink is followed to its target's content"
else bad "a symlink is followed to its target's content"; fi

ln -s link.txt chain.txt                       # chain: chain -> link -> real
"$SNAP" chain.txt >/dev/null 2>&1
[ $? -le 1 ] && ok "a symlink chain does not crash" || bad "a symlink chain does not crash"

ln -s loop_b.txt loop_a.txt; ln -s loop_a.txt loop_b.txt   # a -> b -> a
( "$SNAP" loop_a.txt >/dev/null 2>&1 ) & pid=$!
for _ in $(seq 1 20); do kill -0 $pid 2>/dev/null || break; sleep 0.25; done
if kill -0 $pid 2>/dev/null; then kill -9 $pid 2>/dev/null; bad "a symlink loop terminates" "hung, killed after 5s"
else ok "a symlink loop terminates without hanging"; fi

ln -s /nonexistent/path broken.txt
"$SNAP" broken.txt >/dev/null 2>&1
[ $? -eq 0 ] && ok "a broken symlink is not an error" || bad "a broken symlink is not an error"

mkdir -p node_modules && printf 'dep\n' > node_modules/pkg.js
ln -s node_modules/pkg.js sneaky.txt
"$SNAP" sneaky.txt >/dev/null 2>&1
if find .attic -type f -exec grep -lq '^dep$' {} + 2>/dev/null; then
  note "a symlink reaches content inside an excluded directory (exclusions apply to the link path, not the resolved target)"
else ok "a symlink into an excluded directory is skipped"; fi

if store_is_sane "$R"; then ok "the store is sane after every symlink probe"; else bad "the store is sane after every symlink probe"; fi

echo
echo "=== 3. zone guard: case handling and its blast radius ==="
if command -v jq >/dev/null 2>&1; then
  G="$REPO/hooks/immutable-zone-guard.sh"
  C=$(mktemp "$TESTTMP/conf.XXXXXX")
  printf '*/records/*\tRecords are records.\n' > "$C"
  deny_for() { printf '{"tool_input":{"file_path":"%s"}}' "$1" | ATTIC_CONF="$C" bash "$G" | grep -c deny; }
  [ "$(deny_for /a/records/f.md)" = 1 ] && ok "denies the configured path" || bad "denies the configured path"
  [ "$(deny_for /a/RECORDS/f.md)" = 1 ] && ok "denies an upper-case variant" || bad "denies an upper-case variant"
  [ "$(deny_for /a/ReCoRdS/f.md)" = 1 ] && ok "denies a mixed-case variant" || bad "denies a mixed-case variant"
  # nocasematch must not make the guard match things it should not.
  [ "$(deny_for /a/recordsxyz/f.md)" = 0 ] && ok "case-insensitivity did not widen the pattern" || bad "case-insensitivity did not widen the pattern"
  [ "$(deny_for /a/working/f.md)" = 0 ] && ok "an unrelated path is still allowed" || bad "an unrelated path is still allowed"

  echo
  echo "=== 4. zone guard: malformed configuration ==="
  probe_conf() { printf '%b' "$1" > "$C"; printf '{"tool_input":{"file_path":"%s"}}' "$2" | ATTIC_CONF="$C" bash "$G" 2>/dev/null | grep -c deny; }
  [ "$(probe_conf '*/records/*\n' /a/records/f.md)" = 1 ] && ok "a rule with no reason still denies" || bad "a rule with no reason still denies"
  # Regression: an indented rule used to parse to an empty pattern and be
  # skipped without a word, so a guard that looked configured enforced nothing.
  [ "$(probe_conf '   */records/*   Reason.   \n' /a/records/f.md)" = 1 ] && ok "an indented rule is still enforced" || bad "an indented rule is still enforced" "rule silently ignored"
  [ "$(probe_conf '\t*/records/*\tReason.\n' /a/records/f.md)" = 1 ] && ok "a tab-indented rule is still enforced" || bad "a tab-indented rule is still enforced"
  [ "$(probe_conf '*/records/*\tReason with\ttabs.\n' /a/records/f.md)" = 1 ] && ok "tabs between pattern and reason work" || bad "tabs between pattern and reason work"
  [ "$(probe_conf '# only a comment\n' /a/records/f.md)" = 0 ] && ok "a comment-only config denies nothing" || bad "a comment-only config denies nothing"
  [ "$(probe_conf '' /a/records/f.md)" = 0 ] && ok "an empty config denies nothing" || bad "an empty config denies nothing"
  [ "$(probe_conf '*/records/*  Reason.' /a/records/f.md)" = 1 ] && ok "a final line with no newline is still read" || bad "a final line with no newline is still read"
  [ "$(probe_conf '*/records/*  Reason.\r\n' /a/records/f.md)" = 1 ] && ok "CRLF line endings are tolerated" || note "CRLF line endings break rule parsing"
  rm -f "$C"
else
  note "zone-guard probes skipped (jq not installed)"
fi

echo
echo "=== 5. bash 3.2: empty arrays under set -u ==="
if [ -x /bin/bash ]; then
  v=$(/bin/bash -c 'echo $BASH_VERSION')
  R=$(new_root); cd "$R" || exit 1
  printf 'x\n' > f.txt; mkdir -p d && printf 'y\n' > d/g.txt
  /bin/bash "$RUN" --dir d -- true >/dev/null 2>&1
  [ $? -eq 0 ] && ok "attic-run with only --dir and no file targets (bash $v)" || bad "attic-run with only --dir, no file targets (bash $v)"
  /bin/bash "$RUN" f.txt -- true >/dev/null 2>&1
  [ $? -eq 0 ] && ok "attic-run with only file targets and no --dir (bash $v)" || bad "attic-run with only file targets, no --dir (bash $v)"
  /bin/bash "$SNAP" --root >/dev/null 2>&1
  [ $? -eq 0 ] && ok "attic-snap --root under bash $v" || bad "attic-snap --root under bash $v"
else
  note "bash 3.2 probes skipped (/bin/bash not present)"
fi

echo
echo "=== 6. concurrency: many snapshots of one file at once ==="
R=$(new_root); cd "$R" || exit 1
printf 'concurrent content\n' > c.txt
for _ in $(seq 1 25); do ( "$SNAP" c.txt >/dev/null 2>&1 ) & done
wait
n=$(find .attic/c.txt -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$n" -eq 1 ]; then ok "25 simultaneous snapshots of identical content stored exactly 1 version"
else note "25 simultaneous snapshots stored $n versions (dedupe is check-then-write, not atomic)"; fi
if store_is_sane "$R"; then ok "no corrupt version after concurrent writes"; else bad "no corrupt version after concurrent writes"; fi

echo
echo "=== 7. containment: can anything be written outside the store? ==="
R=$(new_root); cd "$R" || exit 1
OUTSIDE="$TESTTMP/outside-canary"; mkdir -p "$OUTSIDE"; before=$(find "$OUTSIDE" -type f | wc -l | tr -d ' ')
printf 'x\n' > normal.txt
for target in "../../../etc/hosts" "/etc/hosts" "$OUTSIDE/../outside-canary" "normal.txt/../normal.txt" '$(touch /tmp/attic-pwned)' '`touch /tmp/attic-pwned2`' '; touch /tmp/attic-pwned3'; do
  "$SNAP" "$target" >/dev/null 2>&1
done
after=$(find "$OUTSIDE" -type f | wc -l | tr -d ' ')
[ "$before" = "$after" ] && ok "no file created outside the store" || bad "no file created outside the store" "$before -> $after"
ls /tmp/attic-pwned /tmp/attic-pwned2 /tmp/attic-pwned3 >/dev/null 2>&1 \
  && { bad "no command execution from a crafted filename"; rm -f /tmp/attic-pwned*; } \
  || ok "no command execution from a crafted filename"
# Everything the store did write must live under .attic.
stray=$(find "$R" -type f -newer "$R/.attic-root" -not -path "$R/.attic/*" -not -name normal.txt -not -name .attic-root 2>/dev/null | wc -l | tr -d ' ')
[ "$stray" -eq 0 ] && ok "every written file landed under .attic/" || bad "every written file landed under .attic/" "$stray stray files"

cd / || exit 1; rm -rf "$TESTTMP" /tmp/attic-pwned* 2>/dev/null
echo
echo "$PASS passed, $FAIL failed, $NOTE noted"
echo "(notes are findings that need a judgement call, not automatic failures)"
[ "$FAIL" -eq 0 ]
