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

- PowerShell 7+
- `claude` on `PATH` ([Claude Code](https://claude.com/claude-code))
- git

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
| `phasekit gates` | Run the gates yourself, no agent, no cost |
| `phasekit logs [-Follow]` | Show or tail the newest run log |

Useful flags: `-Detach` (survives closing the terminal), `-DryRun` (print the prompt and
the exact `claude` command, run nothing), `-NoBranch`, `-Model`, `-Effort`, `-MaxRetries`,
`-WaitMinutes`.

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
