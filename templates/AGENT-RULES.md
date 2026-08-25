# AGENT-RULES.md

Standing rules for any agent working in this repository. `PLAN.md` says what to do;
this file says how to behave while doing it. Paste it into your `CLAUDE.md`, or keep it
as a file the phase prompts point at.

## The gates

<!-- Keep this identical to PLAN.md section 1.1 and to the gates array in phasekit.json.
     Three copies is already one too many; three copies that disagree is a bug factory. -->

```
cd backend  && pytest -q          # 0 failed
cd backend  && pyright            # 0 errors
cd frontend && npm run build      # exit 0
```

Run them before every commit, not once at the end. A phase that ends with one commit
containing six tasks is a phase that cannot be reviewed or reverted.

## Committing

- One task, one commit, Conventional Commit message.
- The message says **why**, not what — the diff already says what.
- Documentation that the change invalidated is updated in the same commit.
- Never commit anything the repository policy keeps local: agent instruction files,
  editor config, credentials, local databases.

## Stopping

Stop and report — do not improvise — when:

- a task's premise turns out to be false (the file it describes has moved, the bug it
  fixes is already fixed, the claim it makes about the repo is wrong);
- a gate that was green before your change is red after it and you cannot see why;
- the change the task asks for would break an invariant in PLAN.md section 2;
- you would have to add a dependency the task did not name.

Reporting a wrong plan is the most useful thing you can do. Quietly doing a different,
easier task is the least useful.

## Reporting

End every run with:

1. What you committed, one line per commit.
2. The exact gate results — numbers, not "all green".
3. Anything you noticed and did not act on.
4. What is genuinely next.

## Verification honesty

Never report a check you did not run, and never describe an expected result as an
observed one. If a gate could not run, say so and say why. The whole method depends on
the ledger and the report being true; a single invented "green" propagates into every
later phase.
