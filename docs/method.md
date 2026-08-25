# The method

The problem this solves is not "how do I get an agent to write code". It is: **how do I
get a week of agent work into a repository I still trust.**

Left alone, a capable agent will happily produce four hours of changes in one session. The
diff is three thousand lines, the tests pass, the commit message says "refactor", and the
only verdicts available to you are *keep all of it* or *throw all of it away*. Neither is
a review. The method below exists to make a third verdict possible: *keep these six
commits, revert that one, and the eighth was based on a false premise so let's talk*.

## Four artefacts

| File | Answers |
|---|---|
| `PLAN.md` | What needs doing, why, in what order, and how you'll know |
| `PROMPTS.md` | Exactly what each session is told, verbatim |
| `AGENT-RULES.md` | How to behave while doing it |
| `phasekit.json` | Where the code is, and what "green" means as a command |

They are separate because they change at different rates. The plan changes as you learn.
The rules almost never change. The gates change when the toolchain does. Merging them
produces a file too long to keep true.

## Phases

A phase is one session's worth of work: a handful of related tasks, on its own branch,
that make sense to merge or discard together.

Phases are ordered by dependency, not by appeal. In practice the order is almost always:

1. **Reproducibility first.** Lockfiles, pinned versions, tests that pass on a clean
   machine, CI. Nothing measured before this is trustworthy, because you cannot tell a
   regression from a different dependency resolution.
2. **Subtraction second.** Delete the dead feature, the abandoned subsystem, the duplicate
   README. Every later task gets cheaper. This is the phase people skip and regret.
3. **Robustness third.** The bugs that only appear under load, concurrency, or real data.
4. **Then** packaging, then debt, then new features.

Writing the new feature first is what everyone wants to do and it is why the codebase
needed a plan in the first place.

## Tasks

A task is one commit. If it cannot be one commit, it is two tasks.

Each task states four things, and a task missing any of them will produce a question
instead of a commit:

- **Problem** — what is wrong *now*, with evidence. A file and a line, or a command and
  its output. Not "the error handling is inconsistent".
- **Change** — exactly what to do.
- **Blast radius** — what else this touches. This is what stops a two-line fix from
  quietly becoming a rewrite.
- **Done when** — the observable condition. Ideally a command and its expected output.

The discipline that matters most: **write the evidence, not the impression.** A task built
on "I think there's a leak somewhere in the session handling" will consume a session in
investigation and end in a question. A task built on "`SessionLocal` is bound at import
time in `db.py:14`, so the six tests in `test_scan.py` write to the real `case.db`" gets
executed.

## Gates

The gates are the only shared definition of "it works" between you and the agent. They
must be exact commands, from a stated directory, with a stated expected result.

Two rules:

**Define them once.** They appear in `PLAN.md` for the human, in `phasekit.json` for
`phasekit gates`, and in `AGENT-RULES.md` for the agent. Keep them identical. Three
definitions that disagree is worse than one that is slightly wrong.

**Make sure they can actually be green.** A gate that has never passed is not a gate, it
is an aspiration, and the first run will stop to tell you so — which is the correct
behaviour and an expensive way to learn it. Run `phasekit gates` before the first run.

The most common version of this mistake: a type checker or linter that resolves a
different interpreter than you think it does, so its "0 errors" is unreachable on any
machine including yours.

## The check-first pattern

Every phase prompt opens by verifying the previous phase actually landed — and explicitly
by **not** trusting the ledger:

```
CHECK FIRST — verify Phase 0 actually landed, do not trust the ledger:
  1. The gates are all green.
  2. <a greppable consequence of task 0.1>
  3. <a greppable consequence of task 0.2>
  4. Every Phase 0 box is ticked AND has a commit behind it in git log.
Report each as pass or fail. If any fails, STOP and tell me.
```

This costs a couple of minutes per phase and it is the highest-return thing in the whole
method. Unattended runs end early. Sessions hit usage limits mid-task. A tick gets applied
before the commit that earns it. Once the ledger and the repository disagree, every later
phase is built on a claim rather than a fact, and you find out four phases later when
something inexplicable breaks.

Recording the baseline in phase 0 matters for the same reason: "631 passed, 1 failed" is a
number later phases can be compared against. "The tests mostly pass" is not.

## Stopping is a success

The rule that does the most work in `AGENT-RULES.md`:

> If a task turns out to be wrong or impossible, stop and report instead of improvising.

Plans are written by humans from a snapshot of a repository, and some of their premises
are wrong by the time they execute. A task that says "commit the modified lockfile" when
the lockfile is tracked and clean is not a task; it is a stale observation. The valuable
outcome is the agent telling you so. The expensive outcome is the agent finding something
plausible to do instead and ticking the box.

So: budget for questions, and answer them into the same conversation
(`phasekit reply <phase>`) rather than restarting the phase. The agent has already run the
whole baseline; answering costs one turn, restarting costs all of it.

## Reviewing

Review at the commit, not at the branch. Read the messages first: seven commits with seven
distinct reasons is a good sign; three commits called "refactor", "fixes" and "more fixes"
means the phase was executed as one blob and the ledger is decorative.

Then `phasekit status` — ledger next to git log — and merge with `--no-ff` so the phase
stays visible as a unit in the history:

```powershell
git checkout master
git merge --no-ff plan/phase-0
```

Or, if the phase went badly, `git branch -D plan/phase-0` and rewrite the plan. That
option existing is the entire point.
