# Design note: chunked batch hashing

Status: not implemented. This note exists so whoever picks it up (human or
agent) inherits the thinking and the traps, not just the idea.

## Assigning this work

Handing this file to the implementing session, plus one instruction, is
the whole handoff: follow the repo's established pattern. That means
regression tests written first and watched fail for the right reason, the
adversarial probes listed below shipped in the same change, and the
benchmark re-run as the finishing check. The existing tests this note
points at (the `cp` shim in `tests/test-attic.sh`, the store-sanity walk
in `tests/test-adversarial.sh`) are the house style to imitate, so no one
has to rediscover it.

## The problem

A sweep (`attic-run --dir`, or `--stdin0` generally) hashes every file to
decide whether its bytes are already stored. Hashing is one process per
file, and process startup is the dominant cost: measured 2026-08 on an
Intel Mac, a 200-file sweep where nothing changed takes about 7 s, roughly
35 ms per file, almost all of it spent starting hash processes. Batch
hashing replaces those 200 invocations with one `openssl dgst -sha1 -r`
call per chunk of files. Expected win for unchanged sweeps: 3-5x.

## The invariant that must not move

`snap_one` uses hashes for two different jobs, and only one of them may be
batched:

1. **The skip decision** (dedupe fast path): hash the live file; if those
   bytes are already stored, do nothing. Batching this is the entire win,
   and it is safe: a wrong hash here can at worst cause one unnecessary
   copy or delay one snapshot. It can never mislabel a stored version.
2. **Naming what is stored**: the version filename carries the hash of the
   copied bytes, computed from the temp copy after `cp`, per file. This is
   what makes a version's name always match its content (see the
   2026-08-21 review: hashing the live file and copying afterwards stored
   mid-rewrite bytes under the old hash, and dedupe then refused to ever
   store the old bytes again). **This hash stays per-file, always.**
   Changed files are rare in a sweep, so keeping it per-file costs almost
   nothing.

## The design

In the `--stdin0` path:

1. Collect candidate files, applying the existing per-file gates first:
   exists, readable, not excluded, within `ATTIC_MAX_BYTES`, and the name
   contains no newline. Files with newlines in their names go through the
   existing per-file path untouched; do not try to be clever with them.
2. Chunk the candidates (a few hundred per chunk keeps argument bytes
   safely under ARG_MAX).
3. One hash invocation per chunk. All three supported tools accept
   multiple file arguments and print one line per file in argument order:
   `openssl dgst -sha1 -r`, `shasum -a 1`, `sha1sum`. Keep the same
   detection order `content_hash` already uses.
4. Correlate output to input **by position only**. Never parse filenames
   out of hasher output; the filename side of the output line is exactly
   where newline and formatting differences between tools live. Input
   order is the only safe join key. Take the first 8 hex characters of
   each line.
5. Per file: if the store has that hash, skip; otherwise fall into the
   existing copy, hash-the-copy, rename flow, unchanged.

## The trap that makes this easy to get subtly wrong

A file that disappears or becomes unreadable between collection (step 1)
and hashing (step 3) produces an error on stderr and **no stdout line**.
Positional correlation then silently shifts: every file after the failed
one is paired with its neighbor's hash. Wrong skip decisions follow, and
under agent-speed churn that is exactly the moment a snapshot matters.

The guard: after each chunk, require output line count == input file
count, and require every line to start with 40 hex characters. On any
mismatch, discard the entire chunk's output and re-run that chunk through
the per-file path. Correct-but-slow is the acceptable degradation;
fast-but-misattributed is not.

## Probes that must exist before this merges

Add to `tests/test-adversarial.sh`:

- A chunk containing a filename with an embedded newline alongside normal
  files: the normal files are batch-hashed, the odd one is handled, and
  the store stays sane.
- A file deleted after collection but before hashing (a hasher shim that
  removes it, in the style of the existing `cp` shim in
  `tests/test-attic.sh`): assert no file is skipped with a wrong hash and
  no stored version's name disagrees with its bytes.
- The existing mid-snapshot rewrite test (the `cp` shim) must stay green:
  it is the proof that the naming hash still comes from the copy.

A useful blanket assertion for all of these: walk the store and re-hash
every version, requiring the name's hash field to match the content. The
test suite already does this for single files; make it a helper and run it
after every batch probe.

## Done-when

- All suites green, adversarial run at least three times (it contains
  races).
- The 200-file benchmark from the README's performance section: unchanged
  sweep at or under ~2 s on the same machine class, with the first-run
  number no worse than before.

## Related, smaller levers

- The per-file `wc -c` size gate could become one `stat` call per chunk.
  Same positional rules apply; `stat` flags differ between BSD (`-f %z`)
  and GNU (`-c %s`), so detect once like the hash tool.
- Parallelism (`xargs -P` style) is safe because per-file work is
  independent and the final rename is atomic, but do it after batch
  hashing, which changes what is left to parallelize.
