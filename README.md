# attic

Keep a copy of every file before an AI coding agent overwrites it.

Agents edit files fast, in bulk, and without asking. Most of the time that is
the point. The rest of the time you want the previous version back, and `git`
only helps if the file was committed, tracked, and clean when it happened.

Attic is about 200 lines of `bash` with no dependencies beyond `jq` for the
hooks. It stores one copy per distinct version, deduplicated by content hash,
and it never blocks a write.

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
never destroy the newer one.

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
interrupted halfway, the previous version is already stored.

The exit status is the command's own and the wrapper's messages go to stderr,
so it drops into a pipeline or a Makefile without changing behavior.

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
snapshots that file before the tool changes it. It never denies a write and
never reports failure into the session: a backup mechanism that can break the
thing it protects is worse than none.

To confirm it is working, edit any existing file through the agent and run
`attic-snap --list` on it. A version should be there.

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
your own words. Without `attic.conf`, the guard denies nothing.

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
and editor swap and lock files.

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

42 tests covering root resolution, deduplication, filenames with spaces,
exclusions, the size limit, list and restore, external files, the command
wrapper, and both hooks.
Two are security regressions for a case-sensitivity bypass that let a write
past the immutable-zone guard by changing the case of a path. The suite runs in
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

## License

Apache 2.0. See [LICENSE](LICENSE).
