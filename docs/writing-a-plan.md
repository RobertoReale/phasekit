# Writing a plan

The plan is the work. Everything else in this repository is a hundred lines of PowerShell.

## Start from an audit, not from ideas

Before writing a single task, spend one session doing nothing but reading:

```
Read the repository and tell me what is actually here: what each module does, what the
tests cover, what the build produces, and what is dead. Then tell me the ten things most
likely to bite: unpinned dependencies, tests that depend on the developer's machine,
error paths with no handler, docs that contradict the code. Give me evidence for each —
a file and a line, or a command and its output. Change nothing.
```

Save the answer. Most of the plan comes out of it, and the parts that don't come out of it
are usually the parts you were wrong about.

## Shape of a task

```markdown
### 0.1 Isolate the database in the test suite

**Problem.** `SessionLocal` is bound at import time in `app/db.py:14`, so the six tests
in `test_scan.py` write to the real `case.db`. On a machine where that file does not
exist yet, they fail; on a machine where it does, they corrupt it silently.

**Change.** Bind the engine and the session factory inside a fixture, parameterised on
a `tmp_path` database. No production code changes.

**Blast radius.** `conftest.py` and any test that imports `SessionLocal` directly.

**Done when.** `pytest -q` passes with `case.db` deleted, and `case.db` is not recreated
by the run.
```

Four sections, one commit. The **Done when** is what makes it unattended: it is the
condition the agent checks before ticking the box, and the condition you check when you
review.

## What makes a task fail

**A premise instead of evidence.** "The error handling is inconsistent" produces a session
of investigation and a question. "`scrape()` swallows `TimeoutError` at `scrapers/base.py:212`
and returns an empty list, so a network failure is indistinguishable from zero results"
produces a commit.

**Two changes in one.** "Refactor the router and add pagination" cannot be reviewed,
because you cannot tell which half broke the thing that broke.

**No stated blast radius.** Without it, a task grows to fill the session.

**A "done when" that is a feeling.** "Done when the code is cleaner" is not checkable, so
the box gets ticked on vibes.

## Order the phases by dependency

Ask of each phase: *if I do this after that one instead, does it get more expensive?*

Reproducibility first — until the build is deterministic you cannot tell a regression from
a different dependency resolution, so every measurement before it is noise. Deletion second
— every subsequent task is cheaper against a smaller codebase, and deleting a subsystem you
have just refactored is the purest waste in software. Then robustness, then packaging, then
debt, then features.

## Decision gates

Some tasks should not be executed until you have answered a question. Mark them, and say so
in the prompt:

```
THEN: execute PHASE 1 in order. Task 1.3 is a decision gate: ask me the question it
specifies and wait for my answer before touching anything related to email import.
Do 1.1, 1.2 and 1.4 regardless of that answer.
```

Note the last sentence. Without it, a decision gate blocks the whole phase and you have
paid for a session that did nothing but ask a question.

## Invariants

The plan's other job is to protect what already works. Write down the things that must not
break — and, crucially, *why*, with the incident that caused them:

> 14. The API binds to loopback only by default. It has no authentication; a
>     non-loopback default would expose the whole database to the local network.
>
> 17. Settings tests must never read the real `settings.json`. One did, once, and sent
>     a real email from the developer's account during a test run.

An invariant without a reason gets refactored away by the next agent that finds it odd.
An invariant with a reason gets a test written for it instead.

## Keep the plan true

The plan is read by every session. A stale claim in it is not a harmless typo — it is an
instruction. When an agent reports that a premise is false, fix the file before continuing;
when a phase changes something the plan describes, the plan is part of that commit.

The `audit` prompt in `PROMPTS.md` exists for this: run it occasionally and let a session
tell you which parts of your own document are no longer true.
