# Troubleshooting

Every entry here is a failure that has actually happened. Most of them are quiet — they
produce no error message at all, which is what makes them expensive.

## The run stopped and I can't tell whether it failed or asked me something

They look identical from outside: non-zero exit, no more output. `phasekit` prints the
last 40 lines of the log for exactly this reason.

Read the tail. An agent that stopped to ask ends with a paragraph addressed to you; a
crash ends with a stack trace or a truncated tool call.

- It asked a question → `phasekit reply <phase> -File answer.txt`. This resumes the same
  conversation, so the baseline it already ran is not repeated.
- It crashed or was killed → `phasekit continue <phase>`.

Write long answers into a file rather than `-Text`. Shell quoting mangles multi-line text,
and you will want to edit the answer twice before sending it.

## My answer went somewhere else entirely — the agent never saw it

The classic silent failure. `claude -c` means *the most recent conversation in this
directory*. If you have an interactive Claude Code session open in the same folder, that
one is more recent than the headless run, and `-c` resumes **it**. Your answer lands in a
different conversation, no error is printed anywhere, and the headless run stays stopped.

`phasekit` avoids this by capturing the session id from the stream and writing it to
`.phasekit/logs/phase-<n>.session`, then always resuming with `--resume <id>`.

To confirm which conversation a run is in, look at the `init` line at the top of the log:

```
18:35:29  session 2088965d-085f-4646-830f-72c50f5b9638  cwd C:\...\my-project
```

If you ever see `No pinned session id — falling back to -c`, stop and pass `-Session <id>`
explicitly instead.

## The run died and there was no error

First rule out the boring explanation: **a run waiting out a usage limit looks exactly
like a dead one.** No `claude` process, a log that stopped growing, work sitting
uncommitted mid-task. See [Usage limits](#usage-limits) below. The runner's own window is
the tell — it says what it is waiting for and until when.

If it really did die, it is almost always one of three things:

**You pressed Ctrl+C.** The `claude` process is a child of the shell that launched it.

**You closed the terminal.** Same reason.

**You killed the parent.** Killing the launcher kills the run it started, even if the run
itself was healthy.

Use `-Detach` for anything long:

```powershell
phasekit run 3 -Detach
phasekit logs -Follow
```

The run then lives in its own process, and closing the window it was launched from does
nothing to it. To check whether it is alive: `phasekit status` reports running `claude`
processes.

**Ask the dashboard, which does not guess.** Everything else on it is inferred from files
that outlive the process that wrote them, so a sequence killed an hour ago and one merely
between targets draw identically. The `runner` line is the exception — the runner records
which process it is, so the answer is a fact rather than an inference:

```
  runner    process 36108, since 03/09 18:12
  runner    no process — the runner was killed on H.5, it did not stop
```

The second line is the one worth waiting for. A killed run writes no `auto-stopped.txt`
and sounds no notice, because the process that would have done both is the one that died —
this line is the only place it is ever said.

## The context window filled up

The log ends with something like `prompt is too long: 214431 tokens > 200000 maximum`, or
`input length and max_tokens exceed context limit`, or a failed compaction.

This is handled, and it is handled differently from the other two recoverable endings:
phasekit starts a **fresh** conversation on the same target rather than resuming the one
that overflowed. Resuming would replay the transcript that was too long in the first
place, fail again on the first turn, and burn a retry doing it. The new conversation gets
the continue prompt, which re-establishes what landed from the gates, `git status` and the
git log — safe precisely because the progress is in the branch, the commits and the
ledger, and never in the transcript.

You will see it in the log:

```
[phasekit] Context window full. Picking the same target up in a fresh conversation
(restart 1 of 2) - the branch, the commits and the ledger carry what was done.
```

If it happens twice on the same target, phasekit stops and asks for you. A third restart
would be a loop spending the whole allowance re-reading the same plan, and that is the
plan's problem, not the runner's: the target is too big, or it is asking the agent to read
more than it needs. Split it. `"usageLimit": { "maxContextRestarts": 2 }` sets the count if
you disagree.

One thing it deliberately does **not** do: treat the agent's own words as the signal. An
agent that writes "my context is getting long" is describing its situation, not ending,
and restarting a session that was still working is worse than the problem. Only the
runtime's own error counts.

## The run stopped and left work uncommitted

An interruption mid-task leaves edits on disk with no commit. `git status` is dirty and the
ledger is behind reality.

```powershell
phasekit status <phase>     # see the commits and the dirty files
phasekit continue <phase>
```

`continue` explicitly tells the agent to establish the truth from `git log` and
`git status` before doing anything, because its own memory of what it finished is not
evidence. Do **not** start the phase over: `run` refuses on a dirty tree precisely so that
this mistake needs a deliberate `-NoBranch` or a stash.

## `run` refuses because the tree is dirty

That is the point — starting a phase on top of uncommitted work makes the resulting diff
unreviewable. Commit it, stash it, or if the mess is leftover from an interrupted run of
this same phase, use `continue` instead.

`"requireCleanTree": false` in `phasekit.json` disables the check if you really mean it.

## A gate can never be green

Run `phasekit gates` before your first `run`. If a gate has never passed, the first thing
the agent does is stop and tell you, which is correct but slow.

The usual cause is a tool resolving a different interpreter or config than you assume — a
type checker picking up the system Python instead of the project's virtualenv, a linter
reading a config from a parent directory. Pin it explicitly in the project's own config
file, so the documented command works on any machine, and so CI runs the same thing you do.

Second most common: the gate assumes an optional dependency is installed. Decide which
side of the line it is on and write it down — either the dependency is required, or the
gate must be green without it.

## The agent says a task's premise is false

It is usually right. Plans are written from a snapshot; by the time a phase executes, the
file may have moved, the bug may be fixed, the "currently uncommitted" file may be tracked
and clean.

Fix `PLAN.md` rather than waving the task through — a false claim left in the plan will be
read again by every later phase. Then answer with the corrected instruction via
`phasekit reply`.

## The ledger says a task is done but there is no commit

The failure the check-first pattern exists to catch. It means a run ended between the tick
and the commit, or the agent ticked optimistically.

`phasekit status` prints the ledger next to the git log. Untick the box, then
`phasekit continue <phase>`.

## The wait never ended — the machine slept through it

The runner is alive, there is no `claude` process, the log stopped at the limit message,
and the announced reset came and went. Nothing resumes.

`Start-Sleep -Seconds 10000` measures a timer, and a suspended machine neither advances
it nor reliably fires it on resume. A three-hour wait for a usage limit is precisely the
workload Windows decides is idle, so the machine suspends *into* the wait and the run
never wakes up on the other side.

Two changes, both in the runner:

- The wait is now against a wall-clock deadline, in short sleeps. Whatever happens to the
  machine in between, the first tick past the deadline ends it.
- The whole sequence holds `ES_SYSTEM_REQUIRED`, so the machine stays up while an
  unattended run is in flight. The display is left alone — the screen still turns off.

A wait now also writes to the run log, not only the hidden console, so `phasekit logs
-Follow` shows a countdown instead of a log that just stops. That was the ambiguity
underneath this whole failure mode: a run waiting out a limit and a dead run look
identical from the outside.

If you find one hung in the old way, it is safe to kill: `Stop-Process -Id <pid>`, then
rerun `phasekit auto`. The target it was on has a pinned session and a branch, so the
sequence resumes that conversation rather than restarting the phase.

## Usage limits

`claude -p` does not wait and resume by itself when the allowance runs out; it exits with
an error. `phasekit` detects that specific failure and resumes the same conversation, up
to `maxRetries` times. Anything that is *not* a usage limit stops immediately — a broken
test is not worth retrying blindly.

**How long it waits.** The limit message usually says when the allowance comes back:

```
You've hit your session limit ⎿ resets 10:50pm (Europe/Rome)
```

`phasekit` reads that time and sleeps until it. This matters more than it looks: a fixed
twenty-minute wait against a reset three hours away burns every one of six retries without
ever reaching it, and the run gives up two hours early having spent six pointless
round-trips. When no time can be read — a wording change, a timezone that makes the
answer implausible — it falls back to `waitMinutes`, and says which of the two it used:

```
Usage limit reached. Waiting 172 min (until the announced reset), resuming at ~22:52 (attempt 1 of 6).
```

A run inside this wait has **no `claude` process** and a log that stopped growing. That is
the healthy state, and it is indistinguishable at a glance from a dead run — check the
runner's own window, or `phasekit status`, before concluding anything died.

If the limit pattern ever fails to match a new wording, the run stops with the log tail
visible, which is the safe direction to fail in.

## `auto` stopped on a target it had just merged

`auto-stopped.txt` says the merge preconditions failed, but `git log` on the main
branch shows the merge commit sitting there, and the tree is clean. Both statements
are true: the merge happened, and the runner then read it as a failure.

The cause is PowerShell's, not git's. A function returns **everything** written to
the output stream, not just what `return` names. A bare `git merge` or `git log`
inside a function that ends in `return 0` makes the caller receive
`@('Merge made by the ort strategy.', '12 files changed…', 0)`. Comparing that array
with `-ne 0` yields the non-matching elements — a non-empty array, which is truthy —
so `if ($merged -ne 0)` fires on success.

Fixed in the runner by piping every native command inside a value-returning function
to `Out-Host`, and by reading exit codes as `@(Invoke-Thing)[-1]`. If you extend
`phasekit` yourself, that is the rule: **a function that returns an exit code may not
let anything else reach the output stream.** `Write-Host` is safe; a bare `git`,
`npm` or `python` call is not.

How to tell this is what happened: the stop reason mentions the merge or the gates,
but `phasekit status` shows a clean tree, the ledger ticked, and the phase branch
already an ancestor of main. Rerunning `phasekit auto` is safe — targets that are
ticked *and* merged are skipped, so it picks up at the next real one.

## `Get-Content: The 'Raw' and 'Tail' parameters cannot be specified in the same command`

An old bug in hand-rolled runners: reading the log tail crashes the error handler, so the
real failure is never printed. Join the lines instead:

```powershell
$tail = (Get-Content $log -Tail 40) -join "`n"
```

Worth knowing because the crash appears *inside* the code that was supposed to explain
what went wrong, which makes it look like the runner itself is broken.

## `the branch has no commits on it`, but the phase clearly did the work

The agent reports a finished task, the gates are green, the tree is clean — and
verification stops the sequence saying the phase branch is empty. It is empty. The
commit went to the *other* repository.

This only happens in the split layout, where the plan lives in its own notes repo
beside the code repo. Most phases change code, so measuring a phase by the commits on
its code branch works nearly always — until a task is purely a documentation task and
lands entirely in the notes repo. Then the measurement is looking in a place the work
was never going to be, and reports a success in the words of a failure.

`phasekit` now marks both repositories when a phase starts: the `.base` file holds the
code repo's HEAD on line one and the notes repo's on line two. A branch with no
commits is only a problem when the notes repo has nothing new either. `merge` prints
the notes commits in that case, so an empty branch reads as an answer rather than as
something missing.

The notes repo is found from the **plan's** directory, not from `workingDir` —
`workingDir` is the common parent of the two checkouts and is usually not a repository
at all, whereas the plan is by definition inside the notes repo.

A run started before this existed has a one-line `.base` file, and is read the old way:
an unmeasurable claim is not evidence. If you hit the stop on such a run, check the
notes repo's log by hand before treating it as a failure.

## `auto` wants to redo the whole plan, or skips everything

Both symptoms come from the same place: the plan file is gone. Deleting a finished
plan is the last task of this workflow, so this is a state the tool has to survive.

`Test-TargetDone` normally needs two things to agree — every ledger box ticked, and
the branch merged. With no ledger there is nothing to agree with, so the repository
alone decides, and one rule flips: a **missing branch** means "merged and tidied away"
when a ledger confirms it, and "never started" when nothing does. With no plan, no
branch now means not done. Redoing finished work costs a session; skipping unfinished
work builds everything after it on sand.

If you hit this on an older checkout, the symptom was `auto` starting again from the
first target of the sequence.

## A target that legitimately produces no commit

Some targets do their work outside both repositories — retiring a repository on the
host, publishing a release, flipping a setting. Verification would call that an empty
branch and stop the sequence. Mark the entry instead:

```json
{ "target": "7.4", "allowNoCommits": true, "note": "archives the notes repo on GitHub" }
```

It is deliberately per-target and opt-in. Making it the default would remove the check
that catches the far more common case: a phase that reported success and produced
nothing.

Naming targets with `-Targets` reuses their configured entries, so this flag, the
per-target model, and the note all still apply when you rerun a single one by hand.
