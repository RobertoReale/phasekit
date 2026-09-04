# PROMPTS.md — one phase, one block

`phasekit run <phase>` finds the `## Phase <phase>` heading below and sends the fenced
block under it verbatim. Nothing else in this file reaches the agent, so the block has to
stand on its own.

**Every block opens with a verification of the one before it.** That is deliberate: an
unattended run can end early, leave a task half-committed, or tick a box it did not earn.
The check is cheap — mostly running the gates plus a grep or two — and it is the only
thing standing between "phase 2 built on phase 1" and "phase 2 built on what phase 1 was
supposed to have done".

When a check fails the instruction is always the same: **stop and report, do not repair
silently and do not continue.** A failed check means the ledger and reality disagree, and
that is a fact worth seeing rather than a mess worth hiding.

---

## Phase 0 — <name>

Nothing precedes this one, so the check is a baseline reading rather than a verification.

```
Read AGENT-RULES.md and PLAN.md.

CHECK FIRST: run the gates from PLAN.md section 1.1 and report the exact result of
each — how many tests pass and fail, the error count, whether the build succeeds.
This is the starting baseline; record it in your final report so later phases have
something to compare against. If something is broken in a way PLAN.md does not
describe, tell me before touching anything.

THEN: execute PHASE 0 in order. Follow the rules of engagement in section 1.2. For
each task: make the change, run the gates, update any documentation the change
invalidates, commit separately with a Conventional Commit message, and tick the task
in the ledger (section 8).

If a task turns out to be wrong or impossible, stop and report instead of
improvising. Do not start Phase 1.
```

---

## Phase 1 — <name>

```
Read AGENT-RULES.md and PLAN.md.

CHECK FIRST — verify Phase 0 actually landed, do not trust the ledger:
  1. The gates (section 1.1) are all green.
  2. <a concrete, greppable consequence of task 0.1>
  3. <a concrete, greppable consequence of task 0.2>
  4. Every Phase 0 box in the ledger is ticked AND has a commit behind it in git log.
Report each as pass or fail. If any fails, STOP and tell me — do not fix it silently
and do not continue into Phase 1.

THEN: execute PHASE 1 in order. Same rules as always: one commit per task, gates
green, docs updated in the same commit, ledger ticked. Stop at the end of the phase.
```

---

## resume

Use when you do not remember where a run stopped. `phasekit continue <phase>` resumes the
pinned conversation instead; this one starts fresh and works out the truth from the repo.

```
Read AGENT-RULES.md and PLAN.md. Look at the progress ledger, run the gates, and check
whether the last ticked task is actually reflected in the code — a ticked box with no
matching commit means a session ended early, and uncommitted edits in `git status` mean
one ended mid-task. Then tell me which task is genuinely next and what it involves.
Change nothing.
```

---

## task — any single task

Used automatically by `phasekit run <task>` whenever the target has a dot in it —
`phasekit run 4.2` sends this block with `{{TASK}}` replaced by `4.2`. One generic block
instead of one per task, which would be twenty near-identical copies waiting to drift.

`{{SECTION}}` is replaced with that target's own section of the plan. Use it, and do not
ask the agent to read the plan: a real plan reaches a hundred kilobytes, and what a
session reads it does not read once — it carries it in the context of every request it
makes afterwards.

```
Read AGENT-RULES.md.

The task itself is quoted at the end of this prompt. Do not read all of PLAN.md:
grep it for the one line you need (the ledger row, a neighbouring task) instead.

CHECK FIRST: the gates are green, the working tree is clean, and the task
immediately before {{TASK}} in the ledger is both ticked and backed by a commit in
git log. Report each; if any fails, STOP and tell me.

THEN: execute task {{TASK}} and nothing else. Respect every constraint listed under
it — those are the invariants the task is most likely to break.

One commit. Gates green before it. Documentation updated in the same commit. Tick
the ledger. Then stop.

Keep the context small as you work: read the part of a file you need rather than
the whole file, pipe long command output through `tail`, and never read a lock file.

--- the task, quoted from PLAN.md ---

{{SECTION}}
```

---

## audit

```
Read AGENT-RULES.md and PLAN.md, then check the documentation against the code. Report
what is stale, what is untrue, and any invariant with no test covering it. Cross-check
the ledger against the git log: every ticked task should have a commit behind it.
Change nothing.
```
