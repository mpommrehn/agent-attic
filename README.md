# attic

Keep a copy of every file before an AI coding agent overwrites it.

Agents edit files fast, in bulk, and without asking. Most of the time that is
the point. The rest of the time you want the previous version back, and `git`
only helps if the file was committed, tracked, and clean when it happened.

Attic is about 200 lines of `bash` with no dependencies beyond `jq` for the
hooks. It stores one copy per distinct version, deduplicated by content hash.
Everything fails closed and fails loudly: if a previous version cannot be
preserved, the destructive step is refused and the reason says why, because
silent unprotection is the one failure mode a safety net must never have.

```
$ attic-snap notes.md
attic: /work/notes.md -> /work/.attic/notes.md/2026-08-20T144428Z.c88cbd31.md

$ attic-snap --list notes.md
2026-08-20T151203Z.2410d456.md
2026-08-20T144428Z.c88cbd31.md

$ attic-snap --restore .attic/notes.md/2026-08-20T144428Z.c88cbd31.md notes.md
attic: /work/notes.md -> /work/.attic/notes.md/2026-08-20T152014Z.9f1abc02.md
attic: restored .attic/notes.md/2026-08-20T144428Z.c88cbd31.md -> notes.md
```

Restoring snapshots the current file first, so recovering an old version can
never destroy the newer one. If that safety snapshot cannot be stored, the
restore is refused instead; see
[If something is refused](#if-something-is-refused).

## Documentation

- [docs/scope.md](docs/scope.md) — what this covers and, more importantly, what
  it does not. Read this before relying on it.
- [docs/pattern.md](docs/pattern.md) — the method-here-instance-there split that
  keeps the tool this small, and how to apply it to your own agent rules.

## What it does not do

Read [docs/scope.md](docs/scope.md) before relying on this. It protects against
**overwrites**, not against unsaved in-editor work, and not against losing the
directory. Those are different problems with different
owners, and treating one mechanism as if it covered all three is how people end
up confidently unprotected.

## Install

No build step. Clone it and put `bin` on your `PATH`:

```bash
git clone https://github.com/mpommrehn/agent-attic.git
cd agent-attic
export PATH="$PWD/bin:$PATH"      # add to ~/.zshrc or ~/.bash_profile to keep it
```

`zsh` and `bash` read different startup files, so a `PATH` entry in one is
invisible to a fresh shell of the other kind. To confirm it worked, open a new
terminal and run `command -v attic-snap`.

Runs on macOS and Linux with the system `bash` (3.2 is enough). The two hooks
need `jq`; nothing else does. Hashing uses `openssl`, `shasum`, or `sha1sum`,
whichever is present.

## Mark the directory you want protected

Attic needs to know what counts as your working root, because that is what the
store mirrors. It resolves the root in this order:

1. `ATTIC_ROOT`, if set
2. the nearest parent directory containing `.attic-root` or an existing `.attic`
3. the git top level

For a directory that is not a git repo, or a repo holding several independent
roots, create the marker:

```bash
cd ~/work/my-project
touch .attic-root
attic-snap --root          # confirm it resolves to what you expect
```

## Use it

### By hand, before you change something

```bash
attic-snap path/to/file            # one word, before you start
attic-snap --list path/to/file     # what versions exist
find src -type f -print0 | attic-snap --stdin0    # a whole tree, one process
```

### Around a script that writes files

The snapshot hook only sees an agent's own file-editing tools. A generator, a
build step, a formatter, or a shell redirect is invisible to it. `attic-run`
closes that gap: it snapshots first, then runs the command.

```bash
attic-run report.docx -- node generate-report.js
attic-run --dir src -- npx prettier --write src/
attic-run schema.sql -- ./migrate.sh
```

Everything before `--` is a file or `--dir` to preserve; everything after is
the command, passed through untouched. Snapshots happen first and
unconditionally, so if the command then fails, writes garbage, or is
interrupted halfway, the previous version is already stored. If a snapshot
itself fails, the wrapper refuses to run the command and exits 2: better a
refused command than a destructive one with nothing preserved.

The exit status is the command's own and the wrapper's messages go to stderr,
so it drops into a pipeline or a Makefile without changing behavior. The one
exception: exit status 2 together with an `attic-run:` line on stderr means
the wrapper refused before running anything at all.

### Automatically, for every agent edit

For Claude Code, register the snapshot hook as a `PreToolUse` hook on
`Write|Edit|NotebookEdit` in `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write|Edit|NotebookEdit",
        "hooks": [
          { "type": "command", "command": "/absolute/path/to/agent-attic/hooks/attic-snapshot.sh" }
        ]
      }
    ]
  }
}
```

The hook reads the tool payload on stdin, pulls out the target path, and
snapshots that file before the tool changes it. It fails closed: if the
snapshot cannot be taken (no resolvable root, a broken install, missing
`jq`), the write is denied with the reason, because an edit that silently
proceeds unprotected defeats the point of installing the hook. Brand-new
files pass through untouched, and policy skips (exclusions, the size cap)
count as success. Register it per project rather than in user-level
settings: in a directory with no resolvable working root the hook blocks
writes by design, which is what you want in a protected project and pure
friction everywhere else.

To confirm it is working, edit any existing file through the agent and run
`attic-snap --list` on it. A version should be there. If the hook refuses a
write instead, [If something is refused](#if-something-is-refused) maps
every message to its fix.

Other agent runtimes can use the same script if they can run a command before a
file write and hand it JSON with a `file_path` field. `attic-snap` itself has no
Claude-specific parts.

## Freeze the things that are records, not drafts

Some paths hold documents whose value depends on them *not* having changed:
an invoice as sent, a signed contract, an audit log, a filed report. If an
agent can quietly edit one, it proves nothing, and proving something is the
entire reason it is kept.

Copy `attic.conf.example` to `attic.conf` and list those paths:

```
*/invoices-sent/*   Immutable zone: an invoice as sent is a record, not a draft.
*/signed/*          Immutable zone: countersigned documents are evidence.
```

Then register the guard the same way as the snapshot hook:

```json
{ "type": "command", "command": "/absolute/path/to/agent-attic/hooks/immutable-zone-guard.sh" }
```

Writes to a matching path are denied outright, and the agent is told why in
your own words. Rules match the canonical path as well as the literal one, so
a symlink alias or a relative path cannot slip past them. Matching is
case-insensitive, because case-insensitive filesystems make `/records/` and
`/Records/` the same directory; on a case-sensitive filesystem this errs
toward denying a lookalike path, which is the cheap direction to be wrong in.
Without `attic.conf`, the guard denies nothing. With rules configured but
`jq` missing, it blocks writes instead of silently allowing everything: a
guard that fails must fail closed.

## If something is refused

Attic blocks a step only when proceeding would leave you unprotected, and it
always says why. In an agent session you notice it as an edit the agent
reports as denied, with the reason attached; on the command line the reason
is on stderr. The messages, what they mean, and what to do:

**`could not snapshot ... (attic: no working root found ...)`** — the
snapshot hook fired in a project attic does not know about. Either mark the
root you want protected (`touch .attic-root` there, see
[above](#mark-the-directory-you-want-protected)), or remove the hook from
this project's `.claude/settings.json` if the project should not be
protected. This is the most common refusal by far, and it is a setup
message, not a bug.

**`could not snapshot ...`** with any other reason — the hook ran but the
snapshot failed: a wrong hook path in `settings.json`, a moved clone, an
unreadable file. The parenthetical is the underlying error. To see the same
failure up close, run `attic-snap <that file>` in a terminal in the project.

**`jq is not installed ...`** — both hooks read the tool payload with `jq`
and neither can do its job without it, so both stop rather than pretend.
`brew install jq` or `sudo apt-get install -y jq` and the block is gone.

**Your own zone reason**, like `Immutable zone: ...` — the guard is doing
what `attic.conf` told it to. If that file genuinely needs editing, change
or remove the matching rule. There is deliberately no override flag.

**`attic-run: could not snapshot ...; refusing to run the command`** — the
stderr line above it is the specific failure. Fix that, or run the command
without the wrapper if you accept losing the previous versions.

**`attic: refusing to restore over ...`** — the file currently at the
restore target could not be stored (over the size cap, or on an excluded
path), and restore never overwrites what it cannot preserve. Raise the cap
for one run (`ATTIC_MAX_BYTES=52428800 attic-snap --restore ...`), or move
the current file aside yourself and restore into the empty spot.

None of this can trap you. Removing the hook entries from
`.claude/settings.json` stops all blocking immediately. The store is plain
files with no daemon and no state anywhere else, so `rm -rf .attic` removes
every trace, and uninstalling is deleting the clone.

## Configuration

| Variable | Default | What it does |
|---|---|---|
| `ATTIC_ROOT` | discovered | The working root the store mirrors |
| `ATTIC_DIR` | `$ATTIC_ROOT/.attic` | Where versions are stored |
| `ATTIC_MAX_BYTES` | `10485760` | Files larger than this are skipped |
| `ATTIC_EXCLUDE` | empty | Colon-separated globs to never store |
| `ATTIC_CONF` | `<repo>/attic.conf` | Immutable-zone rules |

`ATTIC_ROOT` is worth setting explicitly in any automated context. Discovery
walks up from the current directory, which is fine interactively and surprising
inside a hook or a scheduled job that starts somewhere you did not choose.

Always excluded: the store itself, `.git`, `node_modules`, `.venv`,
`site-packages`, `__pycache__`, `target`, `dist`, `build`, temp directories,
and editor swap and lock files. Naming an excluded file explicitly prints
`skipped (excluded path)` on stderr, so silence is never mistaken for
protection; `attic-run --dir` sweeps stay quiet about exclusions, since
dropping those trees is what a sweep is for. Zero-byte files are not stored:
there is nothing in them to preserve, and the store never holds an empty
version.

## How versions are stored

```
.attic/<path mirrored from the root>/<filename>/<UTC timestamp>.<sha1-8>.<ext>
.attic/_external/<absolute path>/<filename>/<UTC timestamp>.<sha1-8>.<ext>
```

One copy per distinct content. Re-running on unchanged bytes is a no-op, which
is what makes it safe to call on every write. **Nothing is pruned
automatically** — a text snapshot is a few KB, and a real working root of about
120 files came to 1.4 MB. If that ever becomes a problem, it will be a problem
with a measurable size, which is a better basis for a retention policy than a
guess.

Add `.attic/` to your `.gitignore`. The store is local history, not something
to commit.

## Tests

```bash
tests/test-attic.sh          # does it do what it claims
tests/test-adversarial.sh    # can the claims be broken
```

88 tests covering root resolution, deduplication, filenames with spaces,
exclusions, the size limit, list and restore, external files, the command
wrapper, and both hooks.
Two are security regressions for a case-sensitivity bypass that let a write
past the immutable-zone guard by changing the case of a path. Most of the
rest are regressions from a 2026-08 review: a restore refuses to overwrite a
file whose current content it could not preserve, `attic-run` and the
snapshot hook refuse to proceed when snapshotting fails, the zone guard
canonicalizes paths before matching and fails closed when `jq` is missing,
excluded explicit targets say they were skipped, `--list` and `--restore`
survive a deleted parent directory, `--dir` follows symlinks, and a stored
version's name always matches its bytes because the copy is hashed, not the
live file. The suite runs in
a throwaway root and cleans up after itself, and CI runs it on macOS and Linux
because the filesystem differences between them decide whether the zone guard
works at all.

The adversarial suite adds 29 probes that attack the claims rather than confirm
them: write and delete races against the snapshot, symlink chains, loops, broken
links and links into excluded directories, zone-guard patterns in every case
combination, malformed configuration, empty-array expansion under bash 3.2,
25 simultaneous snapshots of one file, and whether any crafted path can cause a
write outside the store or execute a command. Two real bugs came out of it, both
in the zone guard, both silent failures.

## Why this exists

A cleanup step in an unrelated script ended with `close every document saving
no`. It closed every open document in a word processor and discarded unsaved
changes without prompting. One of those documents held a day of work.

Three things were true and none of them were noticed: the command succeeded at
its stated job, so its success masked its scope; destroying someone else's
document raises no error, so the failure was invisible; and the guard rails in
place at the time covered `rm -rf` and force-pushes but had nothing at all for
application control.

The specific loss was in-memory, and no version store could have caught it.
But the incident made something else obvious: the working root kept no prior
copy of anything, and every agent editing files in it was one bad instruction
away from an unrecoverable overwrite. That gap is what this fixes.

## Future performance ideas

Where it stands, measured on an Intel Mac in 2026-08: a 200-file
`attic-run --dir` sweep takes about 14 s the first time and 7 s when nothing
changed, roughly 35 ms per unchanged file. That is already down 3x from the
per-file-process design, and the remaining cost is process startup for the
hash, not I/O. Linux forks are cheaper, so both the pain and the gains are
smaller there. Ideas, in rough value order, none taken yet:

- **Chunked batch hashing.** One `openssl dgst -sha1 -r` call for hundreds
  of files instead of one per file; the likely 3-5x win for unchanged
  sweeps. Not done yet because the output has to be correlated back to
  filenames positionally and newline-safely, and that is easy to get subtly
  wrong. It should arrive with adversarial probes for exactly that.
- **Batched size checks.** The per-file `wc -c` could be one `stat` call
  per chunk. Same positional-correlation caveat, smaller win.
- **An opt-in mtime+size cache.** Skip hashing files whose size and mtime
  match the previous sweep. This is the fast path every build tool uses,
  and it would make sweeps near-instant, but mtime can lie (some tools
  preserve it while changing content), so it must stay opt-in and the
  hash must remain the default.
- **Parallel sweeps.** Per-file work is independent and the final rename
  into the store is atomic, so an `xargs -P` style fan-out is safe. Only
  worth it after batch hashing, which changes what there is to parallelize.

None of these change what is stored or when; they only change how fast a
sweep decides there is nothing to do.

## License

Apache 2.0. See [LICENSE](LICENSE).
