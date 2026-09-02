# phasekit

Run a long refactor as a series of unattended agent sessions that you can actually review.

One plan, split into phases. One phase per headless run, on its own git branch, one commit
per task, gates green before every commit. The runner survives usage limits, pins the
conversation so your answers reach the right session, and prints what the agent is doing
while it does it.

It exists because "let the agent go and see what happens" produces a diff nobody can read
and a repository nobody can revert. The unit of trust here is the commit, not the session.

## What it is not

It is not a framework, an orchestrator, or a way to avoid thinking about your codebase.
The plan is the product; `phasekit` is the thing that presses play and refuses to let a
bad run look like a good one.

## Requirements

- PowerShell 7+ (Windows, macOS or Linux)
- `claude` on `PATH` ([Claude Code](https://claude.com/claude-code))
- git

### Platform support

Running phases, verifying, merging, waiting out usage limits, detaching and following
logs work the same everywhere. Two things are the operating system's to provide, and
phasekit uses whatever is there:

| | Windows | macOS | Linux |
|---|---|---|---|
| Keep the machine awake during a long wait | `SetThreadExecutionState` | `caffeinate -s` | `systemd-inhibit` |
| Notify when a sequence ends or stops | sound + tray balloon | `afplay` + `osascript` | terminal bell + `notify-send` |

Neither is required. If the mechanism is missing, phasekit says so once and carries on —
a machine with no notification daemon must not take a run down, and a run that cannot
prevent sleep is still a run. The terminal bell is the fallback everywhere, which is
also the one that survives ssh.

`tools/resume-at-logon.ps1` registers a **Windows** Task Scheduler task. Elsewhere it
refuses and prints the launchd or systemd equivalent to set up by hand.

## Install

```powershell
git clone https://github.com/<you>/phasekit.git
```

Then either call it by path, or add a function to your PowerShell profile
(`$PROFILE`) so `phasekit` works anywhere:

```powershell
function phasekit { & "C:\path\to\phasekit\bin\phasekit.ps1" @args }
```

## Quickstart

```powershell
cd my-project
phasekit init          # writes phasekit.json, PLAN.md, PROMPTS.md, AGENT-RULES.md
```

1. Edit `phasekit.json`: point `codeDir` at the git repo, and list the **gates** — the
   exact commands that must be green before every commit.
2. Write `PLAN.md`. This is the work. See [docs/method.md](docs/method.md) and
   [docs/writing-a-plan.md](docs/writing-a-plan.md).
3. Write the phase blocks in `PROMPTS.md`. Each one opens by verifying the previous phase.
4. Check the gates actually run:

```powershell
phasekit gates
```

5. Go:

```powershell
phasekit run 0
```

## Commands

| Command | What it does |
|---|---|
| `phasekit init [-Force]` | Scaffold the four files into the current directory |
| `phasekit run <phase>` | Create `plan/phase-<n>`, send the phase block, stream the run |
| `phasekit reply <phase> -Text "…"` | Answer a question **in the same conversation** |
| `phasekit reply <phase> -File answer.txt` | The same, from a file — easier to edit, survives shell quoting |
| `phasekit continue <phase>` | Pick up an interrupted phase where it stopped |
| `phasekit status [<phase>]` | Branch, dirty files, commits on the phase, ledger vs git log |
| `phasekit dashboard [-Watch]` | How far along, what is running, roughly how much is left |
| `phasekit gates` | Run the gates yourself, no agent, no cost |
| `phasekit auto [-Push]` | Walk `autoSequence` unattended: run, verify, merge, next |
| `phasekit logs [-Follow]` | Follow the run, rolling over to each new phase's log |

Useful flags: `-Detach` (survives closing the terminal), `-DryRun` (print the prompt and
the exact `claude` command, run nothing), `-Watch` (redraw the dashboard), `-NoBranch`,
`-Model`, `-Effort`, `-MaxRetries`, `-WaitMinutes`.

`-Detach` then hands the terminal straight back to following the run, so one command both
starts it and shows it. `Ctrl+C` there stops the *following*; the run is a separate process
and carries on. `-NoFollow` leaves you at the prompt instead, and `phasekit logs -Follow`
reattaches whenever you want. The follower rolls over on its own as each phase opens its
own log, and ends when the sequence does.

## Unattended sequences

`phasekit auto` walks a list of targets on its own: run, verify, merge, next. The list
lives in `phasekit.json`, and each entry may name its own model — the cheap one where the
gates fully cover the change, the expensive one where a mistake would be silent:

```json
"autoSequence": [
  { "target": "4.2", "model": "sonnet", "note": "mechanical move, fully covered by tests" },
  { "target": "4.3", "model": "opus",   "note": "riskiest task in the plan" },
  { "target": "7.2", "model": "sonnet" }
]
```

It **stops at the first target that needs a person** and writes the reason to
`auto-stopped.txt`. Skipping ahead would build every later target on top of something
nobody looked at — and unlike a human, an unattended loop would never notice. A target
that is already ticked *and* merged is skipped, so rerunning after a stop picks up where
it left off.

Leave irreversible steps out of the sequence and run them by hand.

It tells you when it ends, either way — sound and a desktop notice on both the completion
and the stop. The stop is the one that pays for it: a sequence waiting for an answer costs
nothing to fix and everything to not notice. Set `"notify": false` to turn it off.

Everything above survives inside the running process. Nothing inside a process survives
that process dying, so a reboot is the one interruption the runner cannot handle on its
own:

```powershell
tools/resume-at-logon.ps1 -Install -Push -Config path\to\phasekit.json
```

That registers a logon task which resumes the sequence, and does nothing once it has
finished. Resuming is safe to repeat: merged targets are skipped, and a target with a
pinned session is continued rather than restarted.

## How far along, and how much longer

```powershell
phasekit dashboard          # one screen, then back to the prompt
phasekit dashboard -Watch   # the same, redrawn every 20 seconds
```

```
  phasekit  real-estate-search                                 02/09 13:53

  ██████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░   15 / 53   28%

  now       G.8   coordinates on the first run                running 9m
  next      G.9  H.1  H.2

  pace      typical target 25m   quickest quarter 19m   (14 measured)
            5h 52m per target as it has actually gone, waits included

  left      38 targets   ~16h 4m of work   ~9d 6h at the observed pace
  since     29/08 21:59   (3d 15h elapsed)

  0 ████ 4/4   A ██████ 6/6   G █████░░░░░ 5/10   H ░░░░ 0/4   B ░░░░░ 0/5
  C ░░░░ 0/4   D ░░░░░░░░░ 0/9   E ░░░░░░ 0/6   F ░░░░░ 0/5
```

Two estimates, because there are two clocks and on a subscription they disagree by an
order of magnitude. **Of work** is the median target projected over what is left: what the
sequence costs when it is allowed to run. **At the observed pace** is the wall clock since
the first target started, divided by the targets finished within it — allowance resets,
dropped connections and sleeping laptops included.

The gap between the two *is* the reading. Close together, the sequence is running freely
and the estimate is the work. A factor of ten apart, what stands between you and the end
is the allowance, and writing a faster plan would change nothing.

The typical target is a median rather than a mean on purpose: one target that sat out a
weekend waiting for a limit to reset moves a mean by a factor of nine, and an estimate
built on that quotes months.

The dashboard writes nothing and remembers nothing — every number is read fresh from the
repository, the plan and the log directory. That is what makes it honest about a run it
never saw start, one that died without saying so, and a target somebody finished by hand
between sequences, none of which a progress file kept by the runner would have known
about. It is also why a stop marker left behind by a run that was since answered by hand
is reported as probably stale rather than as an alarm: work happening after the marker was
written is the evidence that somebody dealt with it.

## Configuration

`phasekit.json`, found by walking up from the current directory:

```json
{
  "workingDir": ".",
  "codeDir": ".",
  "plan": "PLAN.md",
  "prompts": "PROMPTS.md",
  "logDir": ".phasekit/logs",
  "model": "opus",
  "effort": "high",
  "branchPrefix": "plan/phase-",
  "requireCleanTree": true,
  "usageLimit": { "maxRetries": 6, "waitMinutes": 20 },
  "gates": [
    { "name": "tests", "cwd": "backend",  "run": "pytest -q" },
    { "name": "types", "cwd": "backend",  "run": "pyright" },
    { "name": "build", "cwd": "frontend", "run": "npm run build" }
  ]
}
```

`workingDir` is where the agent is launched; `codeDir` is the git repository that receives
the branch and the commits. They differ when the plan lives in a separate notes repo — set
`workingDir` to their common parent so the agent can see both.

Every relative path is resolved against the config file, never against the shell's current
directory, so the same command means the same thing wherever you type it.

## The three things that make it work

**One commit per task.** A phase you dislike is one `git branch -D` away. A task you
dislike is one `git revert` away. Without this the only available verdict on an hour of
agent work is "keep all of it" or "throw all of it away".

**Every phase verifies the previous one.** Not by reading the ledger — by running the
gates and grepping for the consequences. A ticked box with no commit behind it is the
single most expensive failure in this workflow, because every later phase compounds it.
`phasekit status` prints the ledger next to the git log for exactly this reason.

**Waiting is not failing.** When the subscription allowance runs out, `claude -p` exits
with an error — it does not wait and resume by itself. `phasekit` reads the reset time out
of the message and sleeps until it, then resumes the *same* conversation, so the agent
carries on from the task it was on rather than restarting the phase. A run in that wait
has no `claude` process and a log that stopped growing; it is alive, and it is the single
most common thing to mistake for a crash.

**Stopping is a success.** An agent that stops to say "this task's premise is false" has
done the most valuable thing it can do. The runner shows the log tail when a run ends
non-zero, because a stop-to-ask and a crash look identical from the outside, and answering
costs one turn while restarting the phase costs the whole baseline.

## Documentation

- [docs/method.md](docs/method.md) — why the plan is shaped this way
- [docs/writing-a-plan.md](docs/writing-a-plan.md) — how to write tasks an agent can execute
- [docs/troubleshooting.md](docs/troubleshooting.md) — the failure modes, and what they look like

## Licence

MIT.
