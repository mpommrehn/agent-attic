# Method here, instance there

Attic is one script and two hooks. The reason it stays that small is a pattern
worth describing on its own, because the same shape works for every rule you
want a coding agent to follow.

## The problem

Agent instruction files rot in a predictable way. Someone writes a rule in
`AGENTS.md`. A skill needs the same rule, so it gets copied. A second skill
needs a variation, so a slightly different version appears there. Six months
later the three copies disagree, and nobody knows which one is current — least
of all the agent, which read all three.

The specific failure is always the same: **a fact ended up in more than one
place.**

## The split

Every rule has two halves, and they have different lifetimes.

| | Changes when | Lives in | Read by |
|---|---|---|---|
| **Method** | your thinking changes | one shared doc | every skill that needs it |
| **Instance** | your circumstances change | one config or data file | the same skills, at run time |

Attic is the worked example:

- **Method** is `docs/scope.md`: what a version store covers, what it cannot
  cover, and the rules an agent follows in a root that uses one. It is true for
  anybody. It has no paths in it.
- **Instance** is `attic.conf` and `ATTIC_ROOT`: *your* immutable zones, *your*
  working root. It is true for one machine. It ships as an example file and is
  gitignored in real use.

The script itself hardcodes neither. `attic-snap` discovers the root and reads
the config, so the same 200 lines work in any repo without editing.

## Why this beats the obvious alternative

The obvious alternative is to put everything in the instruction file, because
that is what the agent reads first. It works until the file is long, and then
three things go wrong at once.

**Long files get skimmed, including by models.** A rule buried on line 240 of a
600-line document competes with 239 other lines for attention. A short doc that
a skill loads *because it is about to do that exact task* does not.

**Copies drift silently.** Nothing errors when two files disagree. The agent
follows whichever it read most recently, and the behaviour looks like
randomness rather than like a stale document.

**Circumstance changes force edits to method.** If your immutable zones are
written into the guard script, changing a folder name means editing code. If
they are in a config file, it means editing a list. Only one of those is
reviewable at a glance.

## Applying it

1. **Write the method doc first, with no specifics in it.** If you cannot write
   the rule without naming a path, a company, or a person, you have not
   separated it yet. That is the test.
2. **Name the instance file in the method doc**, and never the other way round.
   The method points at where the data lives; the data does not explain itself.
3. **State the rule that keeps getting skipped, and say it is getting skipped.**
   A doc that reads as a neutral reference gets treated as optional. `scope.md`
   says which mechanism covers unsaved work and which does not, because the
   confusion between them is the actual failure mode.
4. **Say what the mechanism does not do**, in the same document that says what
   it does. Half of a scope doc's value is the out-of-scope list, and it is the
   half people leave out.
5. **One fact, one home.** When a specific belongs in two places, one of them is
   a pointer.

## The smell that tells you it is working

You change a circumstance — a new folder to protect, a renamed project, a
different machine — and you edit exactly one file, which contains no prose.

When that stops being true, something has leaked from the instance side into
the method side, and the next person to change it will have to read code to
find out what your situation is.
