# What attic covers, and what it does not

Read this before relying on it. Conflating the three problems below produces
false confidence, which is worse than having no backup at all.

## Three different problems, three different mechanisms

| Problem | Mechanism | Does attic cover it? |
|---|---|---|
| A file on disk gets overwritten or mangled | Version store | **Yes.** This is the whole job. |
| Edits exist only in an app's memory, never written to disk | The app's own autosave | **No.** Nothing here can help. |
| A whole directory or disk is lost | Off-machine backup | **No.** Use Time Machine, a cloud sync, or a remote. |
| An agent edits a record that should never change | Immutable zones | **Yes**, for paths you configure. |

## In scope

- **Any file an agent overwrites through a file-editing tool.** The snapshot
  hook runs before the write and keeps the previous bytes.
- **Any file a script overwrites**, provided the script calls `attic-snap`
  first. This is the part that depends on you, not on the tool.
- **Files outside the working root.** They are mirrored under `_external/`, so
  a document living elsewhere on the machine is covered the same way.
- **Records you want frozen.** Configured paths are denied to agents outright
  rather than versioned after the damage.

## Explicitly out of scope

- **Unsaved work.** If a document is open in an editor with changes that were
  never written to disk, no version store, snapshot, or filesystem backup
  holds them. Only that application's autosave does. This is not a gap to work
  around; it is a different problem with a different owner.
- **Disaster recovery.** The store lives inside the working root. If the root
  is deleted or the disk fails, the store goes with it. Attic protects against
  *overwrites*, not against *loss of the directory*.
- **Secrets and large binaries.** Files over the size limit are skipped, and
  dependency trees, build output, and temp directories are excluded. The store
  is for source-of-truth documents, not artifacts you can regenerate.
- **Anything outside a file write.** A file deleted with `rm`, a database row
  dropped, a remote resource changed by an API call: none of these pass
  through the hook.
- **Concurrency guarantees.** Two processes snapshotting the same file at the
  same instant is not coordinated. In practice the content hash makes this
  harmless, but it is not a transactional store.

## The rule that matters most

**Address the object you created, never the application's collection.**

That is the general lesson from the incident this tool exists because of. A
cleanup step ran `close every document saving no` in a word processor. It
succeeded at its stated job, it destroyed an unrelated document holding a
day of unsaved work, and destroying someone else's document raises no error,
so nothing in the feedback loop noticed.

`every document`, `active document`, `front window`, and `quit` are the same
mistake wearing different words. Version stores cannot save you from that
class of bug, which is exactly why the rule is written down instead.

## Rules for agents working in a root that uses attic

1. **Never overwrite a file you did not create in this session without a
   snapshot first.** The hook covers file-tool edits. Anything writing through
   a script, a generator, or a shell redirect is your responsibility: call
   `attic-snap` before it runs.
2. **Never write into a configured immutable zone.** If something seems to
   require it, that is a signal the plan is wrong, not that the guard is.
3. **Never close, quit, or discard state in an application you did not open.**
4. **Regenerating an artifact that was already delivered needs a reason, and a
   sentence saying what it is.** The generator is the source of truth; the
   delivered document is a historical record. Both matter, and they are not
   the same file.
