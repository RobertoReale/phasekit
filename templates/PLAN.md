# PLAN.md — <project name>

<!--
  This is the product. phasekit only presses play.

  A plan an agent can execute unattended is not a wishlist: it is a sequence of tasks
  small enough to commit one at a time, each with a stated reason, a stated blast radius,
  and a way to tell whether it worked. Write it once, carefully, and the runs are boring.
  Write it vaguely and every run ends in a question.

  Delete these comments as you fill the file in.
-->

## 1. How this plan is executed

### 1.1 The gates

Every commit must leave all of these green. They are the only definition of "it works"
that both you and the agent share, so they must be exact commands, runnable from a stated
directory, with a stated expected result.

| Gate | Command | Green means |
|---|---|---|
| backend tests | `cd backend && pytest -q` | 0 failed |
| types | `cd backend && pyright` | 0 errors |
| frontend build | `cd frontend && npm run build` | exit 0 |

Copy these same commands into `phasekit.json` so `phasekit gates` runs exactly what the
agent runs. Two definitions of green is one too many.

### 1.2 Rules of engagement

1. **One task, one commit.** Conventional Commit message. A task that cannot be one
   commit is two tasks.
2. **Gates green before every commit**, not at the end of the phase.
3. **Documentation changes in the same commit as the change that invalidated it.** A
   separate "update docs" commit never happens.
4. **No new dependencies** unless the task says so by name.
5. **No behaviour change inside a refactor commit.** If both are needed, that is two
   commits.
6. **If a task turns out to be wrong or impossible, stop and report.** Do not improvise a
   different task. A plan that was wrong is useful information; a silent substitution is
   not.
7. **Tick the ledger only after the commit exists.** A ticked box with no commit behind
   it makes every later phase build on a lie.

### 1.3 Session protocol

Each run executes exactly one phase and stops. It begins by verifying the previous phase
actually landed — not by trusting the ledger — and ends by reporting what it committed.

## 2. Invariants

Things that must not break, with the reason they exist. An invariant without a reason
gets "cleaned up" by the next refactor.

1. <invariant> — <why, ideally with the incident that caused it>
2. ...

Every invariant that can have a test should have one, named so that deleting the
behaviour fails the test rather than the review.

## 3. Phase 0 — <name>

<!-- Phase 0 is usually reproducibility: lockfiles, pinned versions, CI, tests that pass
     on a clean machine. Nothing later is trustworthy until a run is repeatable. -->

**Why this phase exists:** <one paragraph>

### 0.1 <task title>

**Problem.** <what is wrong now, with evidence: a file, a line, a failing command>

**Change.** <exactly what to do>

**Blast radius.** <what else this touches>

**Done when.** <the observable condition, ideally a command and its output>

### 0.2 <task title>

...

## 4. Phase 1 — <name>

...

## 8. Progress ledger

Ticked only when the commit exists. `phasekit status` shows this next to the git log
precisely so the two can be compared.

- [ ] 0.1 <task title>
- [ ] 0.2 <task title>
- [ ] 1.1 <task title>
