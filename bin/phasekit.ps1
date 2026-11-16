#Requires -Version 7.0
<#
.SYNOPSIS
    phasekit — run a long refactor as a series of reviewable, unattended agent sessions.

.DESCRIPTION
    One plan, split into phases. One phase per headless run, on its own git branch, one
    commit per task, gates green before each commit. The runner survives usage limits,
    pins the conversation so answers reach the right session, and prints what the agent
    is doing while it does it.

    The instructions live in PROMPTS.md and PLAN.md, not in this script. There is one
    copy of every instruction rather than two.

.EXAMPLE
    phasekit init                       # scaffold PLAN.md, PROMPTS.md, phasekit.json
    phasekit gates                      # run the project's gates yourself, no agent
    phasekit run 0                      # execute phase 0
    phasekit run 0 -Detach              # same, surviving this terminal closing
    phasekit reply 0 -File answer.txt   # answer a question the agent stopped to ask
    phasekit continue 0                 # pick up an interrupted phase
    phasekit status                     # what actually landed
    phasekit dashboard -Watch           # progress and time left, refreshing
    phasekit steps                      # what each phase and target is about
    phasekit steps G.2                  # that one target, in full
    phasekit logs -Follow               # watch a detached run
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $Command = 'help',
    [Parameter(Position = 1)] [string] $Phase,
    # lessons drop <id>: the lesson to drop.
    [Parameter(Position = 2)] [string] $Item,

    # reply: the answer text, or a file containing it. A file is easier to edit and
    # survives being retyped after a shell mangles the quoting.
    [string] $Text,
    [string] $File,

    # Explicit config path, when the walk-up search would find the wrong one.
    [string] $Config,

    # Per-run overrides of phasekit.json.
    [string] $Model,
    [string] $Effort,
    [int]    $MaxRetries,
    [int]    $WaitMinutes,

    # Which conversation to resume. Normally read from the pinned session file.
    [string] $Session,

    # Work on the current branch instead of creating one per phase.
    [switch] $NoBranch,

    # Run in a separate process that outlives this terminal. The child claude process is
    # otherwise a child of this shell and dies with it — closing the window or pressing
    # Ctrl+C kills a run that may be an hour in.
    [switch] $Detach,

    # Print the resolved prompt and the exact claude command, then stop.
    [switch] $DryRun,

    # logs: tail the newest log as it grows.
    [switch] $Follow,

    # logs: the detailed view - whole commands, the edits, the head of every tool's output.
    [switch] $Full,

    # dashboard: redraw every few seconds instead of printing once and returning.
    [switch] $Watch,

    # forecast: print the estimate as JSON instead of text.
    [switch] $Json,

    # -Detach normally hands the terminal straight back to following the run. This leaves
    # you at the prompt instead.
    [switch] $NoFollow,

    # auto: the targets to walk, overriding autoSequence in phasekit.json.
    [string[]] $Targets,

    # auto: push to the remote after each successful merge.
    [switch] $Push,

    # init: overwrite files that already exist.
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib' 'PhaseKit.ps1')

$script:SessionId = $Session

# How often `phasekit dashboard -Watch` redraws. Slower than it looks: a frame costs
# three git processes and a directory listing, and nothing on it moves faster than a
# target, which is measured in tens of minutes.
$script:DashboardRefresh = 20

# Paths the user typed are relative to the directory they typed them in. Resolve them
# now, because a run later moves to workingDir — which for a two-repo layout is the
# parent — and a perfectly correct `-File answer.txt` would then point nowhere.
foreach ($p in @('File', 'Config')) {
    $v = Get-Variable -Name $p -ValueOnly -ErrorAction SilentlyContinue
    if ($v -and -not [System.IO.Path]::IsPathRooted($v)) {
        $candidate = Join-Path (Get-Location).Path $v
        if (Test-Path $candidate) { Set-Variable -Name $p -Value (Resolve-Path $candidate).Path }
    }
}

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------

function Show-Help {
    @'
phasekit — plan-driven, unattended agent runs

  phasekit init [-Force]           scaffold PLAN.md, PROMPTS.md, phasekit.json here
  phasekit draft [-Text "..."]     an interactive session that interviews you and writes the plan
  phasekit lint                    check the plan mechanically: ledger, sections, sequence, gates
  phasekit models                  which model and effort each target runs on, and why
  phasekit run <phase>             execute one phase on its own branch
  phasekit reply <phase> -Text .   answer a question, in the same conversation
  phasekit reply <phase> -File .   the same, reading the answer from a file
  phasekit continue <phase>        pick up a phase that was interrupted
  phasekit finish <phase>          commit work left on a branch by a lost conversation
  phasekit check <phase>           are the merge preconditions met? changes nothing
  phasekit merge <phase>           verify, show the commits, then merge into main
  phasekit status [<phase>]        branch, commits, dirty files, pinned session
  phasekit dashboard [-Watch]      how far along, what is running, how much is left
  phasekit steps [G|G.2]           what every phase and target is, in the plan's words
  phasekit spend                   what each target cost: requests, peak context, weight
  phasekit forecast [-Json]        when the sequence ends, usage limits and resets included
  phasekit gates                   run the project's gates locally, no agent
  phasekit auto [-Push]            walk autoSequence unattended: run, verify, merge, next
  phasekit logs [-Follow] [-Full]  follow the run; -Full adds whole commands, edits and outputs
  phasekit account [<name>|next]   list the Claude accounts here, or switch the one runs use
  phasekit review <target>         an independent, read-only review of a target's branch
  phasekit lessons                 what the agents learned so far, best first
  phasekit lessons add -Text .     add one by hand: "when <cond> | <lesson> | evidence: <...>"
  phasekit lessons drop <id>       retire one by hand (-Text gives the reason)
  phasekit pause                   stop the sequence now; nothing restarts it until resume
  phasekit resume                  carry on where the pause stopped, same conversation

Options
  -Detach          run in a process that survives this terminal closing, then follow it
  -Watch           dashboard: redraw every 20s instead of printing once
  -Json            forecast: print the estimate as JSON, for another tool to read
  -NoFollow        with -Detach, return to the prompt instead of following
  -DryRun          print the prompt and the claude command, run nothing
  -NoBranch        stay on the current branch
  -Model -Effort   override phasekit.json for this run
  -MaxRetries -WaitMinutes   how long to wait out a usage limit

Read docs/method.md before writing your first PLAN.md. The plan is the product;
this script is only the thing that presses play.
'@ | Write-Host
}

# ---------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------

function Invoke-Init {
    $dest = (Get-Location).Path
    $templates = Join-Path $root 'templates'

    $files = @(
        @{ src = 'phasekit.json'; dst = 'phasekit.json' }
        @{ src = 'PLAN.md';       dst = 'PLAN.md' }
        @{ src = 'PROMPTS.md';    dst = 'PROMPTS.md' }
        @{ src = 'AGENT-RULES.md'; dst = 'AGENT-RULES.md' }
    )

    foreach ($f in $files) {
        $target = Join-Path $dest $f.dst
        if ((Test-Path $target) -and -not $Force) {
            Write-Host "  skip    $($f.dst) (already exists; -Force to overwrite)" -ForegroundColor Yellow
            continue
        }
        Copy-Item (Join-Path $templates $f.src) $target -Force
        Write-Host "  write   $($f.dst)" -ForegroundColor Green
    }

    $gitignore = Join-Path $dest '.gitignore'
    $entry = '.phasekit/'
    $has = (Test-Path $gitignore) -and ((Get-Content -LiteralPath $gitignore) -contains $entry)
    if (-not $has) {
        Add-Content -LiteralPath $gitignore -Value "`n# phasekit run logs and session pins`n$entry"
        Write-Host "  append  .gitignore  ($entry)" -ForegroundColor Green
    }

    Write-Host ''
    Write-Host 'Next:' -ForegroundColor Cyan
    Write-Host '  1. Edit phasekit.json — codeDir, and the gates that must be green before every commit.'
    Write-Host '  2. Write PLAN.md. This is the work; everything else is scaffolding.'
    Write-Host '  3. Paste AGENT-RULES.md into your CLAUDE.md (or keep it as a file the plan points at).'
    Write-Host '  4. phasekit gates   — confirm the gates run and say something true.'
    Write-Host '  5. phasekit run 0'
}

# ---------------------------------------------------------------------------
# Shared run plumbing
# ---------------------------------------------------------------------------

function Initialize-Run {
    <#
        Resolves the config, applies per-run overrides, prepares the log directory and
        moves to the working directory. Returns the config.
    #>
    param([string] $ForPhase)

    $cfg = Get-PhaseKitConfig -Path $Config
    if ($Model) { $cfg.model = $Model }
    if ($Effort) { $cfg.effort = $Effort }
    if ($MaxRetries) { $cfg.maxRetries = $MaxRetries }
    if ($WaitMinutes) { $cfg.waitMinutes = $WaitMinutes }

    if (-not (Test-Path $cfg.logDir)) { New-Item -ItemType Directory -Path $cfg.logDir -Force | Out-Null }
    Set-Location $cfg.workingDir
    return $cfg
}

function New-LogPath {
    param($Config, [string] $Phase)
    $safe = $Phase -replace '[^\w.-]', '_'
    return (Join-Path $Config.logDir ("phase-{0}-{1}.log" -f $safe, (Get-Date -Format 'yyyyMMdd-HHmmss')))
}

function Get-CommonArgs {
    param($Config)

    $a = @(
        '--permission-mode', 'bypassPermissions'
        '--model', $Config.model
        '--effort', $Config.effort
        '--output-format', 'stream-json'
        '--verbose'
    )

    # The ceiling on the conversation. Passed on every invocation, resumes included: a
    # resumed session is the one that has been growing all along and is exactly the one
    # that needs it. 'auto' leaves the decision to the CLI, which is the behaviour this
    # replaced - see the autoCompact note in Get-PhaseKitConfig for what that cost.
    if ($Config.autoCompact -and "$($Config.autoCompact)" -notin @('off', 'none')) {
        $a += @('--autocompact', "$($Config.autoCompact)")
    }

    # With no --mcp-config beside it, this leaves the session with no MCP server at all,
    # the claude.ai connectors included.
    if ($Config.strictMcp) { $a += '--strict-mcp-config' }

    return $a
}

function Start-Detached {
    <#
        Relaunches this script in an independent process. PHASEKIT_DETACHED stops the
        child from detaching again.

        Start-Process joins -ArgumentList with spaces and quotes nothing, so any path
        containing a space arrives at the child split into pieces. Every path here is a
        user path — the script's own location included — so quoting is not optional.
    #>
    param([string[]] $ForwardArgs)

    $pwsh = (Get-Process -Id $PID).Path
    $quote = { param($a) if ($a -match '\s') { '"' + $a + '"' } else { $a } }

    # -ExecutionPolicy and -WindowStyle are Windows concepts. pwsh elsewhere has no
    # execution policy to bypass and no window to hide, and rejects both rather than
    # ignoring them, which would turn detaching into an instant crash.
    $policy = if ($IsWindows) { @('-ExecutionPolicy', 'Bypass') } else { @() }
    $argList = @('-NoProfile') + $policy + @('-File', (& $quote $PSCommandPath)) +
               ($ForwardArgs | ForEach-Object { & $quote $_ })

    $env:PHASEKIT_DETACHED = '1'
    $proc = if ($IsWindows) { Start-Process -FilePath $pwsh -ArgumentList $argList -WindowStyle Hidden -PassThru }
            else { Start-Process -FilePath $pwsh -ArgumentList $argList -PassThru }
    $env:PHASEKIT_DETACHED = $null

    # A child that dies instantly is the normal failure here, and it dies silently
    # because its window is hidden. Confirm it is actually alive before promising it is.
    Start-Sleep -Seconds 3
    if ($proc.HasExited) {
        Write-Host ''
        Write-Host "The detached process exited immediately (code $($proc.ExitCode))." -ForegroundColor Red
        Write-Host 'Run the same command without -Detach to see why.' -ForegroundColor Red
        return 1
    }

    Write-Host ''
    Write-Host "Detached: pid $($proc.Id). It keeps running if you close this window." -ForegroundColor Green
    Write-Host "Watch it:  phasekit logs -Follow"
    Write-Host "Stop it:   Stop-Process -Id $($proc.Id)"
    return 0
}

function Assert-CleanTreeAndBranch {
    <#
        A phase is a branch. A phase you dislike is then one `git branch -D` away, and the
        diff is reviewable as a unit before it reaches master.
    #>
    param($Config, [string] $Phase)

    if ($NoBranch) { return $null }

    $dirty = git -C $Config.codeDir status --porcelain
    if ($dirty -and $Config.requireCleanTree) {
        Write-Host ''
        Write-Host 'The working tree is not clean. Commit or stash before starting a phase:' -ForegroundColor Red
        Write-Host $dirty
        Write-Host ''
        Write-Host "If this is leftover work from an interrupted run, use:  phasekit continue $Phase" -ForegroundColor Cyan
        Write-Host "If it is $Phase's own work, left by a conversation that is gone:  phasekit finish $Phase" -ForegroundColor Cyan
        # throw, not exit: this runs inside an unattended sequence as often as it runs by
        # hand, and `exit` there is uncatchable - it ends the whole run with no stop note,
        # leaving a runner mark that reads as a killed process and invites the watchdog to
        # restart it into this very same refusal.
        throw "the working tree is not clean, so $Phase cannot be started fresh"
    }

    $branch = "$($Config.branchPrefix)$Phase"
    $exists = git -C $Config.codeDir rev-parse --verify --quiet $branch
    if ($exists) {
        # A leftover branch that committed nothing is not work in progress, it is a
        # stale starting point: it still points where the main branch stood when that
        # attempt began. Checking it out verbatim runs the task against a tree missing
        # everything merged since -- which is exactly how a target that stopped early,
        # and was rerun hours later, would quietly build on superseded code and then
        # merge that back.
        #
        # A branch that DOES carry commits is real half-done work. Leave it precisely
        # where it is: moving it would throw that work away, and `phasekit continue`
        # is the path that belongs to it.
        $main = Get-MainBranch -Config $Config
        $own = [int] (git -C $Config.codeDir rev-list --count "$main..$branch")
        $behind = [int] (git -C $Config.codeDir rev-list --count "$branch..$main")
        if ($own -eq 0 -and $behind -gt 0) {
            Write-Host ("  {0} carried no commits and was {1} behind {2}; re-pointing it at {2}." `
                        -f $branch, $behind, $main) -ForegroundColor DarkGray
            git -C $Config.codeDir checkout $main | Out-Null
            git -C $Config.codeDir branch -f $branch $main | Out-Null
        }
        git -C $Config.codeDir checkout $branch | Out-Null
    }
    else { git -C $Config.codeDir checkout -b $branch | Out-Null }

    $base = (git -C $Config.codeDir rev-parse HEAD).Trim()

    # Two lines: the code repo's HEAD, then the notes repo's, when the plan lives in one of
    # its own. A phase can land all of its work in the notes repo — a documentation task
    # does exactly that — and without this second mark there is nothing to measure it
    # against, so verification reads a real success as an empty branch.
    $lines = @($base)
    $notes = Get-NotesRepo -Config $Config
    if ($notes) { $lines += (git -C $notes rev-parse HEAD).Trim() }

    Set-Content -LiteralPath (Join-Path $Config.logDir ("phase-{0}.base" -f ($Phase -replace '[^\w.-]', '_'))) -Value $lines
    return [pscustomobject]@{ name = $branch; base = $base }
}

function Show-RunResult {
    param($Config, [string] $Phase, $Branch, [int] $ExitCode, [string] $LogPath)

    Write-Host ''
    if ($ExitCode -eq 0) {
        Write-Host "Phase $Phase finished." -ForegroundColor Green
    } else {
        Write-Host "Phase $Phase stopped (exit $ExitCode)." -ForegroundColor Red
    }

    if ($Branch) {
        Write-Host ''
        Write-Host "What this run produced on $($Branch.name):" -ForegroundColor Cyan
        # Out-Host, not a bare call: anything a function writes to the output stream becomes
        # part of its return value, and this one is called just before Invoke-Run returns an
        # exit code. Letting git's stdout through here turns `0` into an array, and every
        # `-ne 0` test upstream then reads a successful run as a failure.
        git -C $Config.codeDir --no-pager log --oneline "$($Branch.base)..HEAD" | Out-Host
        git -C $Config.codeDir --no-pager diff --stat "$($Branch.base)..HEAD" | Out-Host

        $leftovers = git -C $Config.codeDir status --porcelain
        if ($leftovers) {
            Write-Host ''
            Write-Host 'Uncommitted leftovers — a task ended without committing:' -ForegroundColor Yellow
            Write-Host $leftovers
        }

        Write-Host ''
        $main = Get-MainBranch -Config $Config
        Write-Host "Review, then merge:  git -C `"$($Config.codeDir)`" checkout $main; git -C `"$($Config.codeDir)`" merge --no-ff $($Branch.name)"
        Write-Host "Or throw it away:    git -C `"$($Config.codeDir)`" checkout $main; git -C `"$($Config.codeDir)`" branch -D $($Branch.name)"
    }

    Write-Host ''
    Write-Host "Log: $LogPath"
}

# ---------------------------------------------------------------------------
# run / reply / continue
# ---------------------------------------------------------------------------

function Restore-PhaseBranch {
    <#
        Puts a resumed run back on the branch its earlier session was working on.

        `continue` used to leave the branch alone, which was right when it resumed a run
        in the same terminal minutes later. It is wrong after a reboot or a killed runner:
        the shell comes back on whatever branch it likes, and the resumed agent would then
        commit the rest of the phase onto it. A dirty tree is expected here — that is the
        work being picked up — so it is not a reason to refuse.
    #>
    param($Config, [string] $Phase)

    if ($NoBranch) { return $null }

    $branch = "$($Config.branchPrefix)$Phase"
    if (-not (git -C $Config.codeDir rev-parse --verify --quiet $branch)) { return $null }

    $current = (git -C $Config.codeDir branch --show-current).Trim()
    if ($current -ne $branch) {
        Write-Host "  Back onto $branch (was on $current)" -ForegroundColor Yellow
        git -C $Config.codeDir checkout $branch | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Cannot get back onto $branch from $current. Sort the working tree out by hand."
        }
    }

    $safe = $Phase -replace '[^\w.-]', '_'
    $baseFile = Join-Path $Config.logDir ("phase-{0}.base" -f $safe)
    $base = if (Test-Path $baseFile) { (Get-Content -LiteralPath $baseFile -TotalCount 1).Trim() }
            else { (git -C $Config.codeDir merge-base (Get-MainBranch -Config $Config) $branch).Trim() }

    return [pscustomobject]@{ name = $branch; base = $base }
}

function Invoke-Run {
    param([string] $Mode)   # 'run' | 'reply' | 'continue' | 'finish'

    if (-not $Phase) { throw "Which phase? e.g.  phasekit $Mode 0" }

    $cfg = Initialize-Run -ForPhase $Phase
    $sessionFile = Get-SessionFile -Config $cfg -Phase $Phase
    $common = Get-CommonArgs -Config $cfg

    switch ($Mode) {
        'run' {
            $prompt = Build-PhasePrompt -Config $cfg -Phase $Phase
            $first = @('-p', $prompt) + $common
        }
        'reply' {
            if ($File) {
                if (-not (Test-Path $File)) {
                    throw "Answer file not found: $File. Write the answer into that file first, " +
                          'or pass the answer inline with -Text "...".'
                }
                $Text = Get-Content -LiteralPath $File -Raw
            }
            if (-not $Text) { throw 'Nothing to say. Pass -Text "..." or -File path.' }
            if (-not $script:SessionId) { $script:SessionId = Get-PinnedSession -Config $cfg -Phase $Phase }
            $prompt = $Text
            $first = (Get-ResumeArgs -SessionId $script:SessionId) + @('-p', $prompt) + $common
        }
        'continue' {
            if (-not $script:SessionId) { $script:SessionId = Get-PinnedSession -Config $cfg -Phase $Phase }
            $prompt = $script:ContinuePrompt
            $first = (Get-ResumeArgs -SessionId $script:SessionId) + @('-p', $prompt) + $common
        }
        'finish' {
            # A fresh conversation over work already on the branch. No --resume: the point
            # of this mode is that there is nothing left to resume.
            # A fix round on the other CLI, or a hand-over after a spent allowance, cannot
            # resume the earlier conversation; it starts here, told why it is taking over.
            $prompt = Get-OrphanedWorkPrompt -Config $cfg -Target $Phase -Handover ([string] $script:ExtraPrompt)
            $first = @('-p', $prompt) + $common
        }
    }

    if ($DryRun) {
        Write-Host ''
        Write-Host '--- prompt ---' -ForegroundColor Cyan
        Write-Host $prompt
        Write-Host '--- command ---' -ForegroundColor Cyan
        Write-Host "claude $($first -join ' ')"
        return 0
    }

    # A fresh run demands a clean tree and creates the branch. Reply, continue and finish
    # join work already in flight, where a dirty tree is the work — but they still have to
    # be on the right branch, which after a reboot they are not.
    $branch = if ($Mode -eq 'run') { Assert-CleanTreeAndBranch -Config $cfg -Phase $Phase }
              else { Restore-PhaseBranch -Config $cfg -Phase $Phase }

    $log = New-LogPath -Config $cfg -Phase $Phase

    Write-Host ''
    Write-Host "  $(Split-Path -Leaf $cfg.plan) — phase $Phase  ($Mode)" -ForegroundColor Cyan
    Write-Host "  Working dir : $($cfg.workingDir)"
    Write-Host "  Code repo   : $($cfg.codeDir)"
    if ($branch) { Write-Host "  Branch      : $($branch.name)" }
    if ($script:SessionId) { Write-Host "  Session     : $($script:SessionId)" }
    Write-Host "  Model       : $(Format-ModelLabel -Model $cfg.model -Effort $cfg.effort -Separator ' / effort ')"
    Write-Host "  Context     : compacts at $($cfg.autoCompact)"
    Write-Host "  Log         : $log"
    Write-Host "  Usage limit : wait $($cfg.waitMinutes) min, resume, up to $($cfg.maxRetries) times."
    Write-Host ''

    $exit = Invoke-AgentWithLimitRetry -Config $cfg -Phase $Phase -FirstArgs $first `
        -LogPath $log -SessionFile $sessionFile -Common $common

    # Whatever the outcome: a run that failed or stopped is the one most likely to have
    # learned something the next agent should not pay for again.
    $null = Update-LessonsFromLog -Config $cfg -Phase $Phase -LogPath $log

    Show-RunResult -Config $cfg -Phase $Phase -Branch $branch -ExitCode $exit -LogPath $log
    return $exit
}

# ---------------------------------------------------------------------------
# status / gates / logs
# ---------------------------------------------------------------------------

function Invoke-Merge {
    <#
        Merges a finished phase into the main branch, but only once everything a careful
        human would check is true. The point of the branch is that the phase can be thrown
        away; the point of the checks is that "merge it" stops being a decision you make
        while tired.
    #>
    param([switch] $Quiet, [switch] $AllowNoCommits)

    if (-not $Phase) { throw 'Which phase? e.g.  phasekit merge 0' }

    $cfg = Get-PhaseKitConfig -Path $Config
    $main = Get-MainBranch -Config $cfg
    $report = Test-PhaseReady -Config $cfg -Phase $Phase -AllowNoCommits:$AllowNoCommits

    Write-Host ''
    Write-Host "  Merging $($report.branch) into $main" -ForegroundColor Cyan
    Write-Host ''

    foreach ($p in $report.problems) { Write-Host "  BLOCKED  $p" -ForegroundColor Red }

    if ($report.commits.Count -gt 0) {
        Write-Host "  $($report.commits.Count) commit(s) on the branch:" -ForegroundColor Cyan
        foreach ($c in $report.commits) { Write-Host "    $c" }
        Write-Host ''
    } elseif ($report.notesCommits.Count -gt 0) {
        # Say where the work went, so an empty branch reads as the answer it is rather than
        # as something missing.
        Write-Host "  Nothing in the code repository — this phase landed in the notes repository:" -ForegroundColor Cyan
        foreach ($c in $report.notesCommits) { Write-Host "    $c" }
        Write-Host ''
    }

    # Gates run on the branch as it stands, not on whatever the agent last reported. A
    # green report from an hour ago is a claim; this is a measurement.
    # In fast verify mode, away from a checkpoint, the slow gates wait for the milestone's
    # last target (see Get-GatePlan). Said on screen and in the journal, so a merge on the
    # quick gates never reads as a merge on all of them.
    $plan = Get-GatePlan -Config $cfg -Phase $Phase
    Write-Host '  Gates:' -ForegroundColor Cyan
    if (@($plan.deferred).Count -gt 0) {
        $deferred = (@($plan.deferred | ForEach-Object { $_.name })) -join ', '
        Write-Host "  DEFER  $deferred  (fast verify mode: they run at $($plan.next))" -ForegroundColor Yellow
        Write-AutoProgress "  DEFER $deferred to $($plan.next) (fast verify mode)"
    }
    $failed = Invoke-Gates -Config $cfg -Gates @($plan.run)
    Write-Host ''

    # Green on this exact tree: the next target starts from it, and its agent is told so
    # rather than spending a run of every gate to find out (see Get-GreenGatesNote).
    if ($report.ok -and $failed -eq 0) { try { Save-GreenGates -Config $cfg -Gates @($plan.run) } catch { } }

    if (-not $report.ok -or $failed -gt 0) {
        Write-Host 'Not merging.' -ForegroundColor Red
        if ($failed -gt 0) { Write-Host "  $failed gate(s) failing on this branch." -ForegroundColor Red }
        Write-Host ''
        Write-Host "Finish the phase first:  phasekit continue $Phase" -ForegroundColor Cyan
        return 1
    }

    if (-not $Force -and -not $Quiet) {
        Write-Host "Everything checks out. Review the diff before you say yes:" -ForegroundColor Green
        Write-Host "  git -C `"$($cfg.codeDir)`" diff $($report.base)..$($report.branch)"
        Write-Host ''
        $answer = Read-Host "Merge $($report.branch) into $main? [y/N]"
        if ($answer -notmatch '^(y|yes)$') { Write-Host 'Left alone.'; return 1 }
    }

    git -C $cfg.codeDir checkout $main | Out-Host
    git -C $cfg.codeDir merge --no-ff --no-edit $report.branch | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Host 'Merge failed — resolve it by hand. Nothing else here will help.' -ForegroundColor Red
        return $LASTEXITCODE
    }

    Write-Host ''
    Write-Host "Merged into $main." -ForegroundColor Green
    Write-Host "  Push when ready:   git -C `"$($cfg.codeDir)`" push"
    Write-Host "  Tidy the branch:   git -C `"$($cfg.codeDir)`" branch -d $($report.branch)"
    return 0
}

function Invoke-Review {
    <#
        Every reviewer in reviewModel, one after the other, and one verdict out of them:
        TAMPERED if any changed the repository, FAIL if any rejected the work (with every
        rejecting reviewer's findings, each named), PASS if at least one passed it and none
        rejected it, INCONCLUSIVE if none could say. Reviewers of different families make
        fewer errors in common than two of the same (arXiv 2604.21282), though not none
        (arXiv 2609.03422), so a second one is worth its cost where a miss is expensive.
    #>
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] [string] $Target, $Previous)

    $models = @($Config.reviewModels | Where-Object { $_ })
    if ($models.Count -le 1) { return (Invoke-OneReview -Config $Config -Target $Target -Previous $Previous) }

    $results = foreach ($m in $models) {
        $one = [pscustomobject] @{}
        foreach ($p in $Config.PSObject.Properties) { $one | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
        $one.reviewModel = $m
        $r = Invoke-OneReview -Config $one -Target $Target -Previous $Previous
        [pscustomobject]@{ model = $m; verdict = $r.verdict; findings = $r.findings; log = $r.log }
        if ($r.verdict -eq 'TAMPERED') { break }
    }
    $results = @($results)
    $logs = ($results | ForEach-Object { $_.log }) -join ', '
    $tampered = @($results | Where-Object verdict -eq 'TAMPERED')
    if ($tampered.Count) { return [pscustomobject]@{ verdict = 'TAMPERED'; findings = $tampered[0].findings; log = $logs } }
    $failed = @($results | Where-Object verdict -eq 'FAIL')
    if ($failed.Count) {
        $text = ($failed | ForEach-Object { "[reviewer $($_.model)]`n$($_.findings)" }) -join "`n`n"
        return [pscustomobject]@{ verdict = 'FAIL'; findings = $text; log = $logs }
    }
    if (@($results | Where-Object verdict -eq 'PASS').Count) { return [pscustomobject]@{ verdict = 'PASS'; findings = ''; log = $logs } }
    return [pscustomobject]@{ verdict = 'INCONCLUSIVE'; findings = (($results | ForEach-Object { "$($_.model): $($_.findings)" }) -join '; '); log = $logs }
}

function Invoke-OneReview {
    <#
        Runs the independent reviewer on a finished target's branch and returns its verdict:
        PASS, FAIL (with findings), INCONCLUSIVE (no verdict, or the session failed) or
        TAMPERED (the repository changed while it ran, which a read-only reviewer must not
        do - the verdict is then worthless and a person has to look).

        Read-only is enforced by the tools it is given, not asked for: file reads and the
        git commands that only read. Usage limits are waited out like any other run.
    #>
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] [string] $Target, $Previous)

    $report = Test-PhaseReady -Config $Config -Phase $Target -AllowNoCommits
    $base = if ($report.base) { $report.base } else { Get-MainBranch -Config $Config }
    $branch = "$($Config.branchPrefix)$Target"
    $headBefore = ([string] (git -C $Config.codeDir rev-parse HEAD 2>$null)).Trim()
    $treeBefore = (@(git -C $Config.codeDir status --porcelain 2>$null) -join "`n")

    $safe = $Target -replace '[^\w.-]', '_'
    # Not phase-<target>-*.log: those are the target's own runs, and the handoff, the stop
    # notes and the pace statistics read them as such.
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $log = Join-Path $Config.logDir ("review-{0}-{1}.log" -f $safe, $stamp)
    # Two reviews can start within the same second (a quick fix round on a fast machine),
    # and the second must not write into the first one's log.
    for ($n = 2; Test-Path -LiteralPath $log; $n++) { $log = Join-Path $Config.logDir ("review-{0}-{1}-{2}.log" -f $safe, $stamp, $n) }
    $sessionFile = Join-Path $Config.logDir "review-$safe.session"
    Remove-Item -LiteralPath $sessionFile -Force -ErrorAction SilentlyContinue

    $diff = ''
    if ((Get-AgentBackend $Config.reviewModel) -eq 'agy') {
        $diff = (@(git -C $Config.codeDir diff "$base..$branch" 2>$null) -join "`n")
    }
    $prompt = Get-ReviewPrompt -Config $Config -Target $Target -Base $base -Branch $branch -Previous $Previous -Diff $diff
    $common = @(
        '--model', $Config.reviewModel
        '--effort', $Config.reviewEffort
        '--output-format', 'stream-json'
        '--verbose'
        '--allowedTools', 'Read', 'Grep', 'Glob', 'Bash(git diff:*)', 'Bash(git log:*)', 'Bash(git show:*)', 'Bash(git status:*)', 'Bash(git blame:*)'
        '--disallowedTools', 'Edit', 'Write', 'NotebookEdit', 'WebFetch', 'WebSearch'
    )
    if ($Config.autoCompact -and "$($Config.autoCompact)" -notin @('off', 'none')) { $common += @('--autocompact', "$($Config.autoCompact)") }
    if ($Config.strictMcp) { $common += '--strict-mcp-config' }

    Write-Host ''
    Write-Host "  Independent review of $Target  ($($Config.reviewModel) / $($Config.reviewEffort), read-only)" -ForegroundColor Cyan
    Write-Host "  Log: $log"

    # A copy of the config that never restarts on a full context: that restart picks the
    # TARGET up again with its continue prompt, which is not what a reviewer is for.
    $rc = [pscustomobject] @{}
    foreach ($p in $Config.PSObject.Properties) { $rc | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
    $rc.maxContextRestarts = 0
    $savedSession = $script:SessionId
    $script:SessionId = $null
    try {
        $exit = Invoke-AgentWithLimitRetry -Config $rc -Phase $Target -FirstArgs (@('-p', $prompt) + $common) `
            -LogPath $log -SessionFile $sessionFile -Common $common
    }
    finally { $script:SessionId = $savedSession }

    $headAfter = ([string] (git -C $Config.codeDir rev-parse HEAD 2>$null)).Trim()
    $treeAfter = (@(git -C $Config.codeDir status --porcelain 2>$null) -join "`n")
    if ($headAfter -ne $headBefore -or $treeAfter -ne $treeBefore) {
        return [pscustomobject]@{ verdict = 'TAMPERED'; findings = 'the repository changed while the read-only reviewer ran'; log = $log }
    }
    $words = if (Test-Path -LiteralPath $log) { Get-AgentLastWords -LogTail ((Get-Content -LiteralPath $log -Tail 400) -join "`n") -MaxChars 12000 } else { '' }
    $v = ConvertFrom-ReviewVerdict -Text $words
    if ($exit -ne 0 -and $v.verdict -eq 'INCONCLUSIVE') { $v.findings = "the review session ended with exit $exit" }
    Write-Host ("  Review verdict: {0}" -f $v.verdict) -ForegroundColor $(switch ($v.verdict) { 'PASS' { 'Green' } 'FAIL' { 'Yellow' } default { 'DarkYellow' } })
    return [pscustomobject]@{ verdict = $v.verdict; findings = $v.findings; log = $log }
}

function Invoke-Auto {
    <#
        Walks a list of targets unattended: run, verify, merge, next. Stops at the first
        thing that needs a person and says exactly what and where.

        The stop-on-first-problem rule is the whole design. Skipping a failed target to
        "make progress" would build every later one on top of something nobody looked at,
        which is the failure this tool exists to prevent — and unlike a human, an
        unattended loop would not notice it had happened.
    #>
    $cfg = Get-PhaseKitConfig -Path $Config
    if ($Model) { $cfg.model = $Model }
    if ($MaxRetries) { $cfg.maxRetries = $MaxRetries }
    if ($WaitMinutes) { $cfg.waitMinutes = $WaitMinutes }

    # Pin the config path for the rest of the sequence. Each run moves the shell to
    # workingDir, which for a two-repo layout is the parent — and the walk-up search would
    # then fail to find the config it had just been using.
    $Config = $cfg.configPath

    # A pause holds against every automatic start - the logon task, the watchdog, a relaunch
    # script - and is lifted by `phasekit resume`, which removes it before starting this.
    # Exit 0: a start that correctly declined is not a failure for a scheduler to report.
    $paused = Get-PauseState -Config $cfg
    if ($paused -and -not $Force) {
        $where = if ($paused.target) { " at $($paused.target)" } else { '' }
        Write-Host ''
        Write-Host "  This sequence is paused$where. Nothing starts it until:  phasekit resume" -ForegroundColor Yellow
        return 0
    }
    if ($paused) { Remove-Item -LiteralPath (Get-PauseFile -Config $cfg) -ErrorAction SilentlyContinue }

    $sequence = Get-AutoSequence -Config $cfg -Targets $Targets
    $stopFile = Join-Path $cfg.logDir 'auto-stopped.txt'
    $doneFile = Join-Path $cfg.logDir 'auto-finished.txt'
    # Both markers are how a follower knows the sequence ended, and why. A stale one from
    # the last sequence would end the next follow the moment it started.
    Remove-Item -LiteralPath $stopFile -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $doneFile -ErrorAction SilentlyContinue
    Open-AutoJournal -Config $cfg

    # Two runners on one repository is not a race worth having: both merge, both push,
    # and the second one verifies branches the first is still writing. The mark is how
    # they see each other - and how anything else can tell a live sequence from one that
    # was killed without ever getting to say so.
    $runner = Get-RunnerState -Config $cfg
    if ($runner -and $runner.alive -and $runner.pid -ne $PID -and -not $Force) {
        Write-Host ''
        Write-Host ("  A sequence is already running here - process {0}, started {1}, on {2}." -f `
                    $runner.pid, $runner.started.ToString('dd/MM HH:mm'), $runner.target) -ForegroundColor Red
        Write-Host '  Watch it with  phasekit dashboard -Watch , or stop that process first.' -ForegroundColor Cyan
        Write-Host '  -Force starts anyway, which is almost never what you want.' -ForegroundColor DarkGray
        return 1
    }
    if ($runner -and -not $runner.alive -and $runner.here) {
        # The one failure an unattended run cannot report, because the process that would
        # have reported it is the one that died. Say it out loud rather than starting the
        # next sequence as if nothing had happened.
        Write-Host ''
        Write-Host ("  The previous runner (process {0}) was killed while on {1} - it never stopped, it died." -f `
                    $runner.pid, $runner.target) -ForegroundColor Yellow
    }
    Set-RunnerMark -Config $cfg -Target '(starting)'

    Write-Host ''
    Write-Host "  Unattended sequence — $($sequence.Count) target(s)" -ForegroundColor Cyan
    # One reading for the whole listing. Asking per target was three git processes each,
    # which a fifty-target sequence spends half a minute on before it starts working.
    $listing = New-RepoSnapshot -Config $cfg
    foreach ($s in $sequence) {
        $m = if ($s.model) { $s.model } else { $cfg.model }
        $e = if ($s.effort) { $s.effort } else { $cfg.effort }
        $done = Test-TargetDone -Config $cfg -Target $s.target -Snapshot $listing -AllowNoCommits:$s.allowNoCommits
        $mark = if ($done) { 'done' } else { '    ' }
        Write-Host ("    [{0}] {1,-6} {2}/{3}{4}" -f $mark, $s.target, $m, $e, $(if ($s.note) { "   ($($s.note))" } else { '' }))
    }
    Write-Host ''
    if ($Push) { Write-Host '  Pushing after each merge.' -ForegroundColor Yellow }
    Write-AutoProgress ("walking {0} target(s): {1}" -f $sequence.Count,
                        (($sequence | ForEach-Object { $_.target }) -join ', '))

    function Stop-Auto {
        param([string] $Target, [string] $Why, [string] $Next, $Detail)

        # The last lines of whatever failed, in the file itself. The terminal that printed
        # them belongs to a detached process nobody is watching, and telling a reader to go
        # and reproduce a fifteen-minute suite to see one assertion is not a stop note.
        $body = ''
        foreach ($d in @($Detail)) {
            if (-not $d) { continue }
            # A gate has an exit code; what the agent said does not.
            $code = if ($null -ne $d.code) { " (exit $($d.code))" } else { '' }
            $body += "`n--- $($d.name)$code ---`n$($d.tail)`n"
        }

        $text = @"
Unattended sequence stopped at $Target
$(Get-Date -Format 'yyyy-MM-dd HH:mm')

Why: $Why
$body
What to do: $Next
"@
        Set-Content -LiteralPath $stopFile -Value $text
        Write-AutoProgress "STOPPED at $Target - $Why"
        Close-AutoJournal
        # A stop is the runner speaking; it is about to exit on purpose. Leaving the mark
        # behind would report a deliberate stop as a killed process, and an alarm that
        # cries wolf on every ordinary stop is one nobody reads.
        Clear-RunnerMark -Config $cfg
        Write-Host ''
        Write-Host "STOPPED at $Target" -ForegroundColor Red
        Write-Host "  $Why" -ForegroundColor Red
        Write-Host "  $Next" -ForegroundColor Cyan
        Write-Host "  Written to: $stopFile"

        if ($cfg.notify) {
            Send-PhaseKitNotice -Kind 'attention' -Title "phasekit stopped at $Target" -Message "$Why`n`n$Next"
        }
    }

    # A plan with a structural error - a ledger row with no task, a task the sequence never
    # reaches - fails somewhere in the middle of an unattended night. Found here, it costs
    # nothing. Warnings are printed and do not stop anything.
    if ($cfg.lintBeforeAuto -and -not $DryRun) {
        $lint = @(Test-PlanLint -Config $cfg)
        $lintErrors = @($lint | Where-Object level -eq 'error')
        if ($lint.Count) { Write-Host ''; Write-LintFindings $lint }
        if ($lintErrors.Count) {
            Stop-Auto -Target '(the plan)' -Why "the plan has $($lintErrors.Count) error(s), found before any target ran" `
                -Detail ([pscustomobject]@{ name = 'phasekit lint'; code = $null; tail = (@($lintErrors | ForEach-Object { "$($_.where): $($_.message)" }) -join "`n") }) `
                -Next 'phasekit lint   to see them; fix the plan, then rerun phasekit auto ("lintBeforeAuto": false skips this check)'
            return 1
        }
    }

    # Re-resolved on every iteration instead of walked once, so a target appended to
    # autoSequence WHILE the run is going is picked up rather than silently skipped. That
    # skip is not hypothetical: 0.4 was inserted mid-run, never ran, and the target after
    # it then stopped the whole sequence because its predecessor carried no commits.
    # `-Targets` is the exception - an explicit list belongs to the caller, and the config
    # file must not be able to extend it behind their back.
    # -Model and -Effort on the command line are this run's defaults, and a sequence
    # entry overrides them for its own target. They have to be captured before the loop,
    # because the loop assigns to those same variables to pass the per-target choice down
    # to Invoke-Run — which is how `auto -Model sonnet` used to lose its own argument on
    # the first target that did not name a model.
    $cliModel = $Model
    $cliEffort = $Effort

    $attempted = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $answered = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    while ($true) {
        if (-not $Targets) {
            try {
                $fresh = Get-AutoSequence -Config (Get-PhaseKitConfig -Path $Config)
                $known = @($sequence | ForEach-Object { $_.target })
                $added = @($fresh | Where-Object { $known -notcontains $_.target })
                if ($added.Count -gt 0) {
                    Write-Host ''
                    Write-Host ("  autoSequence grew while this run was walking it: {0}" -f `
                                (($added | ForEach-Object { $_.target }) -join ', ')) -ForegroundColor Cyan
                }
                $sequence = $fresh
            }
            catch {
                # A half-written config is a normal thing to catch mid-save. Keep walking the
                # list this run started with rather than dying on somebody's open editor.
                Write-Host (("  autoSequence could not be re-read ({0}) - continuing with the " +
                             "sequence this run started with.") -f $_.Exception.Message) -ForegroundColor Yellow
            }
        }
        $item = @($sequence | Where-Object { -not $attempted.Contains($_.target) })[0]
        if (-not $item) { break }
        [void] $attempted.Add($item.target)
        $target = $item.target
        # The entry's own model, else its tier (named, or read from the plan with autoTier),
        # else the defaults. Said in the journal, with the reason.
        $pick = Resolve-TargetModel -Config $cfg -Item $item -CliModel $cliModel -CliEffort $cliEffort
        $Model = $pick.model
        $Effort = $pick.effort

        if (Test-TargetDone -Config $cfg -Target $target -AllowNoCommits:$item.allowNoCommits) {
            Write-Host "  $target already done — skipping." -ForegroundColor DarkGray
            Write-AutoProgress "$target already done - skipping"
            continue
        }

        if ($item.note) {
            Write-Host ''
            Write-Host "  Note on $target : $($item.note)" -ForegroundColor Yellow
        }

        Write-Host ''
        Write-Host ('=' * 72) -ForegroundColor Cyan
        Write-Host "  $target" -ForegroundColor Cyan
        Write-Host ('=' * 72) -ForegroundColor Cyan

        $Phase = $target
        Set-RunnerMark -Config $cfg -Target $target
        Write-AutoProgress "$target starting"

        # -DryRun prints each target's prompt and stops there. Verifying and merging a
        # run that never happened would report every target as broken.
        if ($DryRun) { Invoke-Run -Mode 'run' | Out-Null; continue }

        # A target with a pinned session and a branch was started by an earlier runner that
        # did not finish — a reboot, a killed process, a machine that slept through the
        # usage-limit wait. Starting it over would throw away everything that session did
        # and, worse, refuse outright, because the half-done work makes the tree dirty.
        # ...but a pin and a branch are only evidence of an ATTEMPT, not of work. A target
        # that stopped before committing anything — a failed precondition, a question asked
        # in its first minute — leaves both behind while having produced nothing. Resuming
        # that session re-asks a question the world may have answered since, and does it on
        # a branch still pointing where the main branch stood back then. Commits on the
        # branch are the only honest evidence there is something to resume.
        $sessionFile = Get-SessionFile -Config $cfg -Phase $target
        $branchName = "$($cfg.branchPrefix)$target"
        $branchExists = [bool] (git -C $cfg.codeDir rev-parse --verify --quiet $branchName)
        $ownCommits = if ($branchExists) {
            [int] (git -C $cfg.codeDir rev-list --count "$(Get-MainBranch -Config $cfg)..$branchName")
        } else { 0 }

        # ...but commits are not the only honest evidence. A session cut off by a usage
        # limit, a dropped connection or a closed laptop can leave a complete change set
        # on disk with nothing committed yet. Dropping the pin there restarts a task that
        # is nearly done, and the fresh run cannot even begin, because it demands a clean
        # tree and the uncommitted work is exactly what makes it dirty.
        $treeDirty = [bool] @(git -C $cfg.codeDir status --porcelain)

        # Two independent questions, and conflating them was a bug: is there work, and is
        # there a conversation? Work on the branch is what decides against starting over -
        # a fresh run would throw that work away and, worse, could not even begin, because
        # it demands the clean tree the work itself is making dirty. Whether a conversation
        # survives only decides HOW to carry on: resuming it if it is there, and a fresh
        # session over the same branch if it is not.
        $hasWork = $branchExists -and ($ownCommits -gt 0 -or $treeDirty)
        $hasSession = Test-Path $sessionFile

        $mode = if ($hasWork -and $hasSession) { 'continue' }
                elseif ($hasWork) { 'finish' }
                else { 'run' }

        if ($hasWork) {
            $evidence = if ($ownCommits -gt 0) { "$ownCommits commit(s) on the branch" }
                        else { 'uncommitted work on disk' }
            Write-Host $(if ($hasSession) {
                "  $target was already started ($evidence) - resuming that session, not restarting the phase."
            } else {
                "  $target was already started ($evidence) and its conversation is gone - a fresh session finishes it."
            }) -ForegroundColor Yellow
            # One shot at finishing it. If the branch still is not ready afterwards, the
            # stop that follows is the honest one rather than a second identical attempt.
            if (-not $hasSession) { [void] $answered.Add($target) }
        }
        elseif ($hasSession) {
            # Drop the pin: leaving it would make the next run take this same wrong turn,
            # and there is no session worth keeping behind a branch with nothing on it.
            Write-Host "  $target left a session behind but committed nothing - starting it fresh." -ForegroundColor Yellow
            Remove-Item -LiteralPath $sessionFile -Force -ErrorAction SilentlyContinue
        }

        Write-AutoProgress ("$target : {0} the agent on {1} ({2})" -f @{
            continue = 'resuming'; finish = 'finishing what was left on the branch with'; run = 'running'
        }[$mode], (Format-ModelLabel -Model $(if ($Model) { $Model } else { $cfg.model }) -Effort $(if ($Effort) { $Effort } else { $cfg.effort })), $pick.source)
        # A precondition that throws - a dirty tree left by the target before this one is
        # the way it happens - used to travel straight out of here and end the process.
        # That leaves a runner mark with no stop note, which reads as a killed runner, so
        # the watchdog restarts it into the very same refusal. Stopping on purpose says
        # what happened once and leaves it said.
        $script:AllowLimitFallback = $true
        $script:LimitFallbackPending = $false
        $script:LimitFallbackList = $null
        try {
            $exit = @(Invoke-Run -Mode $mode)[-1]

            # A spent allowance with limitFallback set: the run returned instead of waiting,
            # and the target goes on, on the next model, in a fresh session over the branch.
            # When the list runs out, the last session waits for its reset as always.
            # The list comes from the run that decided to fall back: this sequence's own copy
            # of the config was read when it started, possibly from another branch's
            # phasekit.json. Measured 2026-11-16: a runner restarted on a task branch made
            # before limitFallback was added read an empty list, and stopped.
            $fbList = if ($null -ne $script:LimitFallbackList) { $script:LimitFallbackList } else { $cfg.limitFallback }
            $fallbacks = @(@($fbList) | Where-Object { $_ } | ForEach-Object { ConvertFrom-ModelSpec $_ })
            $fb = 0
            while ($script:LimitFallbackPending) {
                $script:LimitFallbackPending = $false
                $from = Format-ModelLabel -Model $(if ($Model) { $Model } else { $cfg.model }) -Effort $Effort
                if ($fb -ge $fallbacks.Count) {
                    Write-AutoProgress "$target : limitFallback exhausted - waiting for the reset on $from"
                    $script:AllowLimitFallback = $false
                    $exit = @(Invoke-Run -Mode 'continue')[-1]
                    break
                }
                $next = $fallbacks[$fb]; $fb++
                $Model = $next.model; $Effort = $next.effort
                Write-AutoProgress "$target : usage limit on $from - handing over to $(Format-ModelLabel -Model $next.model -Effort $next.effort)"
                $script:ExtraPrompt = ("The session on $from stopped because its usage allowance ran out, in the middle of " +
                                       "the task. You continue it on another model; nothing of its work is lost.")
                try { $exit = @(Invoke-Run -Mode 'finish')[-1] } finally { $script:ExtraPrompt = '' }
                # From here the target belongs to this model: a "same" fix round must not
                # go back to the one whose allowance is spent.
                $pick = [pscustomobject]@{ model = $Model; effort = $Effort; tier = $pick.tier; source = 'limitFallback' }
            }
        }
        catch {
            Stop-Auto -Target $target -Why "$target could not start: $($_.Exception.Message)" `
                -Next ("Read what it names above - a tree left dirty by the target before this one is the`n" +
                       "  usual cause, and the fix is to finish or discard that work, not to rerun this target.")
            return 1
        }
        finally { $script:AllowLimitFallback = $false }
        Write-AutoProgress "$target : the agent ended with exit $exit"

        # An expired login is a person's to fix: a resume, a reply or a fix round would
        # each meet the same refusal. Say so now, in words that say what to do.
        if ($exit -ne 0 -and $script:LastStopReason -eq 'auth') {
            $who = Get-ActiveAccount
            Stop-Auto -Target $target -Why "the Claude login of account $($who.name) has expired" `
                -Next ("Log in again:  `$env:CLAUDE_CONFIG_DIR = '$($who.dir)'; claude   then /login`n" +
                       "  (or switch to an account that works:  phasekit account <name>), then  phasekit resume.`n" +
                       "  Nothing of $target is lost: its branch and its conversation are kept.")
            return 1
        }

        # Usage limits are already handled inside the run. What reaches here is a question,
        # a crash, or a dropped connection. Only the last of those is worth retrying: a
        # question survives any number of resumes and just gets re-asked, so it stops the
        # sequence — which is correct, because it needs a person.
        $tries = 0
        while ($exit -ne 0 -and $tries -lt 5) {
            $logNow = Get-ChildItem -Path $cfg.logDir -Filter "phase-$($target -replace '[^\w.-]', '_')-*.log" |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $tail = if ($logNow) { (Get-Content -LiteralPath $logNow.FullName -Tail 40) -join "`n" } else { '' }

            if (Test-DeadSession -LogTail $tail) {
                # Resuming a conversation this machine no longer holds is not a failure to
                # retry: the id is gone, and every attempt spends a second arriving at the
                # same sentence. Drop the pin so a later reply or continue does not walk
                # into it as well, and go and judge what the branch actually holds - which,
                # for work committed before the session was lost, is everything.
                Write-Host ''
                Write-Host "  $target's pinned session no longer exists - retrying cannot bring it back." -ForegroundColor Yellow
                Write-Host '  Dropping the pin and judging the branch on what is committed to it.' -ForegroundColor Yellow
                Write-AutoProgress "$target : pinned session gone - judging the branch instead"
                Remove-Item -LiteralPath (Get-SessionFile -Config $cfg -Phase $target) -Force -ErrorAction SilentlyContinue
                break
            }

            if (-not (Test-TransientFailure -LogTail $tail)) {
                if ($tries -eq 0) {
                    # An interruption with no diagnosis at all — a reboot, a killed process —
                    # leaves no marker in the log, so allow exactly one resume before
                    # treating it as something that needs a person.
                    Write-Host ''
                    Write-Host "  $target ended non-zero with no network error in the log — one resume, then I stop." -ForegroundColor Yellow
                } else { break }
            } else {
                Write-Host ''
                Write-Host "  $target hit a network error — resuming in 2 min (attempt $($tries + 1) of 5)." -ForegroundColor Yellow
                Start-Sleep -Seconds 120
            }

            $tries++
            if (-not (Get-PinnedSession -Config $cfg -Phase $target)) {
                Write-Host "  ...and there is no conversation left to resume, so this is where it stops." -ForegroundColor Yellow
                break
            }
            $exit = @(Invoke-Run -Mode 'continue')[-1]
        }

        # A run can end non-zero after its work already landed — the usual way is a runner
        # killed between the merge and the next target. Verifying then reports "not on the
        # phase branch", which is true, describes a success, and is written to
        # auto-stopped.txt in the words of a failure. Ask the outcome, not the exit code.
        if (Test-TargetDone -Config $cfg -Target $target -AllowNoCommits:$item.allowNoCommits) {
            Write-Host "  $target landed and merged despite exit $exit - moving on." -ForegroundColor DarkGray
            Write-AutoProgress "$target : already landed and merged - moving on"
            continue
        }

        $report = Test-PhaseReady -Config $cfg -Phase $target -AllowNoCommits:$item.allowNoCommits
        Write-AutoProgress ("$target : verify {0}" -f $(if ($report.ok) { 'passed' } else { 'failed - ' + ($report.problems -join '; ') }))

        # A task that ended without committing is the one stop with a mechanical answer,
        # so give it here rather than waking somebody to type the same sentence. Once per
        # target: if the same target arrives here a second time the answer was not what it
        # needed, and that stop is the honest one. $Text and $File are read by Invoke-Run
        # out of this scope, the way $Model and $Effort already are.
        # Two ways to finish it, and which one is available decides. With the conversation
        # still there, a reply is far the cheaper: it already knows what it was doing. With
        # the conversation gone - a machine that lost it, or a runtime that never wrote it
        # down - a fresh session is given the work on the branch and the task it was for.
        # Never -c, which continues whatever was last spoken to in that directory: possibly
        # a person's own session, handed an instruction to commit somebody else's work.
        if ((-not $report.ok) -and (Test-UnfinishedWorkStop -Report $report) -and
            (-not $answered.Contains($target))) {
            [void] $answered.Add($target)
            $hasSession = [bool] (Get-PinnedSession -Config $cfg -Phase $target)
            $how = if ($hasSession) { 'reply' } else { 'finish' }
            Write-Host ''
            Write-Host $(if ($hasSession) {
                "  $target ended without committing - answering it once, in the same conversation."
            } else {
                "  $target ended without committing and its conversation is gone - a fresh session finishes it."
            }) -ForegroundColor Yellow
            Write-AutoProgress "$target : ended without committing - $how"
            # An exception here would take the whole sequence down with it, which is worse
            # than the stop it was trying to avoid. Fall through to that stop instead.
            try {
                if ($hasSession) {
                    $Text = Get-UnfinishedWorkAnswer -Target $target
                    $File = ''
                }
                $null = @(Invoke-Run -Mode $how)[-1]
            }
            catch {
                Write-Host "  that did not get through ($($_.Exception.Message))." -ForegroundColor Yellow
            }
            finally { $Text = '' }

            if (Test-TargetDone -Config $cfg -Target $target -AllowNoCommits:$item.allowNoCommits) {
                Write-Host "  $target landed after the answer - moving on." -ForegroundColor DarkGray
                Write-AutoProgress "$target : landed after the answer - moving on"
                continue
            }
            $report = Test-PhaseReady -Config $cfg -Phase $target -AllowNoCommits:$item.allowNoCommits
        }

        if (-not $report.ok) {
            # The problems say what the repository shows; the agent's last message says
            # why, and is usually the question the person is being woken up to answer.
            $lastLog = Get-ChildItem -Path $cfg.logDir -Filter "phase-$($target -replace '[^\w.-]', '_')-*.log" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $words = if ($lastLog) { Get-AgentLastWords -LogTail ((Get-Content -LiteralPath $lastLog.FullName -Tail 400) -join "`n") } else { '' }
            $said = if ($words) { [pscustomobject]@{ name = 'what the agent said last'; code = $null; tail = $words } } else { $null }
            Stop-Auto -Target $target -Detail $said `
                -Why ($report.problems -join '; ') `
                -Next ("Read the log, then answer in the same conversation:`n" +
                       "    phasekit reply $target -Text `"your answer`"`n" +
                       "  ...or -File <path> for a long one, or  phasekit continue $target  to just carry on.")
            return 1
        }

        # Review (when on), then the gates and the merge. A rejection by either is told to
        # the target in its own conversation for as many rounds as fixRounds allows, each
        # optionally on a stronger model; when the rounds run out, the stop is the one this
        # always made. With review off and no rounds, this is exactly the old path.
        $reviewWanted = Test-ReviewWanted -Config $cfg -Item $item
        $rounds = @(Get-FixRounds -Config $cfg)
        $round = 0
        $previousReview = $null
        $landed = $false
        while ($true) {
            $rejection = $null
            if ($reviewWanted) {
                Write-AutoProgress "$target : independent review"
                $review = $null
                try { $review = Invoke-Review -Config $cfg -Target $target -Previous $previousReview }
                catch { $review = [pscustomobject]@{ verdict = 'INCONCLUSIVE'; findings = $_.Exception.Message; log = '' } }
                Write-AutoProgress "$target : review $($review.verdict)"
                if ($review.verdict -eq 'TAMPERED') {
                    Stop-Auto -Target $target -Why 'the repository changed while the read-only reviewer ran' `
                        -Detail ([pscustomobject]@{ name = 'review log'; code = $null; tail = $review.log }) `
                        -Next "git -C `"$($cfg.codeDir)`" status  and  git log  on the branch, then rerun phasekit auto"
                    return 1
                }
                if ($review.verdict -eq 'FAIL') {
                    $rejection = [pscustomobject]@{
                        kind = 'review'; detail = $review.findings
                        why = "the independent review rejected $target"
                        stopDetail = [pscustomobject]@{ name = 'review findings'; code = $null; tail = $review.findings }
                        next = "Read the findings and the review log ($($review.log)), then answer:  phasekit reply $target -File <answer>"
                    }
                }
                elseif ($review.verdict -eq 'INCONCLUSIVE') {
                    # The reviewer is an extra layer, not the gate. Failing to get a verdict
                    # out of it is said, and the gates still decide.
                    Write-Host "  The review gave no verdict ($($review.findings)) - the gates decide alone." -ForegroundColor DarkYellow
                    Write-AutoProgress "$target : review inconclusive - the gates decide alone"
                }
            }

            if (-not $rejection) {
                # Last element, not the whole thing: if any callee ever leaks to the output
                # stream again, this reads the exit code rather than the noise in front of it.
                Write-AutoProgress "$target : merging - the gates run first"
                $merged = @(Invoke-Merge -Quiet -AllowNoCommits:$item.allowNoCommits)[-1]
                if ($merged -eq 0) { break }
                $failures = @(Get-LastGateFailures)
                $rejection = [pscustomobject]@{
                    kind = 'gates'
                    detail = (@($failures | ForEach-Object { "--- $($_.name) (exit $($_.code)) ---`n$($_.tail)" }) -join "`n")
                    why = (Format-GateFailures -Failures $failures)
                    stopDetail = $failures
                    next = "phasekit merge $target   to see what blocked it"
                }
            }

            if ($round -ge $rounds.Count) {
                $more = if ($rounds.Count) { " (after $($rounds.Count) fix round(s))" } else { '' }
                Stop-Auto -Target $target -Why ($rejection.why + $more) -Detail $rejection.stopDetail -Next $rejection.next
                return 1
            }

            $step = $rounds[$round]
            $round++
            if (-not (Get-PinnedSession -Config $cfg -Phase $target)) {
                Stop-Auto -Target $target -Why "$($rejection.why), and its conversation is gone, so no fix round can be held" `
                    -Detail $rejection.stopDetail -Next $rejection.next
                return 1
            }
            $Model = if ($step.model) { $step.model } else { $pick.model }
            $Effort = if ($step.effort) { $step.effort } elseif ($step.model) { $null } else { $pick.effort }
            Write-Host ''
            Write-Host "  $target was rejected ($($rejection.kind)) - fix round $round of $($rounds.Count), $($step.label)." -ForegroundColor Yellow
            Write-AutoProgress "$target : rejected by the $($rejection.kind) - fix round $round of $($rounds.Count) ($($step.label))"
            # The same CLI resumes the target's own conversation. A round on the other one
            # (a Claude target, an "agy:" round, or the reverse) cannot: it starts a fresh
            # session over the branch, told what was rejected.
            $pinned = [string] (Get-PinnedSession -Config $cfg -Phase $target)
            $sessionBackend = if ($pinned -match '^(?i)agy:') { 'agy' } else { 'claude' }
            $roundModel = if ($Model) { $Model } else { $cfg.model }
            $how = if ((Get-AgentBackend $roundModel) -eq $sessionBackend) { 'reply' } else { 'finish' }
            try {
                $message = Get-RejectionMessage -Target $target -Kind $rejection.kind -Detail $rejection.detail -Round "$round of $($rounds.Count)"
                if ($how -eq 'reply') { $Text = $message } else { $script:ExtraPrompt = $message }
                $File = ''
                $null = @(Invoke-Run -Mode $how)[-1]
            }
            catch { Write-Host "  the fix round did not get through ($($_.Exception.Message))." -ForegroundColor Yellow }
            finally { $Text = ''; $script:ExtraPrompt = '' }

            if ($rejection.kind -eq 'review') {
                $lastLog = Get-ChildItem -Path $cfg.logDir -Filter "phase-$($target -replace '[^\w.-]', '_')-*.log" -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
                $answer = if ($lastLog) { Get-AgentLastWords -LogTail ((Get-Content -LiteralPath $lastLog.FullName -Tail 400) -join "`n") -MaxChars 4000 } else { '' }
                $previousReview = [pscustomobject]@{ findings = $rejection.detail; answer = $answer }
            }

            if (Test-TargetDone -Config $cfg -Target $target -AllowNoCommits:$item.allowNoCommits) { $landed = $true; break }
            $report = Test-PhaseReady -Config $cfg -Phase $target -AllowNoCommits:$item.allowNoCommits
            if (-not $report.ok) {
                Stop-Auto -Target $target -Why ("after fix round ${round}: " + ($report.problems -join '; ')) `
                    -Next ("Read the log, then answer in the same conversation:`n" +
                           "    phasekit reply $target -Text `"your answer`"")
                return 1
            }
        }
        # The model and effort a fix round chose belong to that round, not to the next target.
        $Model = $cliModel
        $Effort = $cliEffort
        if ($landed) { Write-AutoProgress "$target : landed during a fix round - moving on"; continue }

        Write-AutoProgress "$target : merged"

        if ($Push) {
            $pushed = @(Invoke-GitPushWithRetry -RepoDir $cfg.codeDir)[-1]
            if ($pushed -ne 0) {
                Stop-Auto -Target $target -Why 'push failed, and retrying did not help' `
                    -Next "git -C `"$($cfg.codeDir)`" push   to see what the remote says, then rerun phasekit auto"
                return 1
            }

            # The notes repo carries the ledger and, for a documentation task, the whole
            # output. Pushing only the code repo leaves that with no copy anywhere else.
            $notes = Get-NotesRepo -Config $cfg
            if ($notes -and (git -C $notes rev-parse --abbrev-ref '@{upstream}' 2>$null)) {
                $notesPushed = @(Invoke-GitPushWithRetry -RepoDir $notes)[-1]
                if ($notesPushed -ne 0) {
                    Stop-Auto -Target $target -Why 'push of the notes repository failed, and retrying did not help' `
                        -Next "git -C `"$notes`" push   to see what the remote says, then rerun phasekit auto"
                    return 1
                }
            }
            Write-AutoProgress "$target : pushed"
        }
    }

    Set-Content -LiteralPath $doneFile -Value @"
Unattended sequence complete
$(Get-Date -Format 'yyyy-MM-dd HH:mm')

Every target ran, verified and merged.
"@
    Clear-RunnerMark -Config $cfg
    Write-AutoProgress 'sequence complete - every target ran, verified and merged'
    Close-AutoJournal
    Write-Host ''
    Write-Host 'Sequence complete. Every target ran, verified and merged.' -ForegroundColor Green
    if ($cfg.notify) {
        Send-PhaseKitNotice -Kind 'done' -Title 'phasekit: sequence complete' `
            -Message "$($sequence.Count) target(s) ran, verified and merged into $(Get-MainBranch -Config $cfg)."
    }
    return 0
}

function Invoke-Status {
    $cfg = Get-PhaseKitConfig -Path $Config

    Write-Host ''
    Write-Host "  $($cfg.configPath)" -ForegroundColor Cyan
    Write-Host "  Code repo : $($cfg.codeDir)"

    $branch = (git -C $cfg.codeDir branch --show-current).Trim()
    Write-Host "  Branch    : $branch"

    $account = Get-ActiveAccount
    $how = if ($account.chosen) { 'chosen with phasekit account' } else { 'from CLAUDE_CONFIG_DIR' }
    Write-Host "  Account   : $($account.name)  ($how)"

    $paused = Get-PauseState -Config $cfg
    if ($paused) {
        $where = if ($paused.target) { " at $($paused.target)" } else { '' }
        $when = if ($paused.since) { ", since $($paused.since.ToString('dd/MM HH:mm'))" } else { '' }
        Write-Host "  Sequence  : PAUSED$where$when - phasekit resume carries on" -ForegroundColor Yellow
    }

    $dirty = @(git -C $cfg.codeDir status --porcelain)
    if ($dirty) {
        Write-Host '  Tree      : dirty' -ForegroundColor Yellow
        foreach ($d in $dirty) { Write-Host "              $d" -ForegroundColor Yellow }
    } else {
        Write-Host '  Tree      : clean' -ForegroundColor Green
    }

    if ($Phase) {
        $safe = $Phase -replace '[^\w.-]', '_'
        $baseFile = Join-Path $cfg.logDir ("phase-{0}.base" -f $safe)
        if (Test-Path $baseFile) {
            $base = (Get-Content -LiteralPath $baseFile -TotalCount 1).Trim()
            Write-Host ''
            Write-Host "  Commits on this phase (since $($base.Substring(0,7))):" -ForegroundColor Cyan
            git -C $cfg.codeDir --no-pager log --oneline "$base..HEAD"
        }
        $pin = Get-PinnedSession -Config $cfg -Phase $Phase
        if ($pin) { Write-Host "`n  Pinned session: $pin" }
    }

    # The ledger is the plan's own claim about what is done. Showing it next to the git
    # log is the whole point: a ticked box with no commit behind it means a run ended
    # early and the plan is now lying to the next session.
    if (Test-Path $cfg.plan) {
        $ledger = Select-String -LiteralPath $cfg.plan -Pattern '^\s*- \[( |x)\]' -AllMatches
        if ($ledger) {
            $done = ($ledger | Where-Object { $_.Line -match '^\s*- \[x\]' }).Count
            Write-Host ''
            Write-Host "  Ledger    : $done of $($ledger.Count) tasks ticked" -ForegroundColor Cyan
            foreach ($l in $ledger) {
                $mark = if ($l.Line -match '^\s*- \[x\]') { 'x' } else { ' ' }
                $colour = if ($mark -eq 'x') { 'DarkGray' } else { 'White' }
                Write-Host ("              [{0}] {1}" -f $mark, ($l.Line -replace '^\s*- \[( |x)\]\s*', '')) -ForegroundColor $colour
            }
        }
    }

    $logs = Get-ChildItem -Path $cfg.logDir -Filter '*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    if ($logs) {
        Write-Host ''
        Write-Host "  Last log  : $($logs[0].Name)  ($($logs[0].LastWriteTime))"
    }

    # Machine-wide, so it counts interactive sessions too. Useful as "is anything alive",
    # not as "is my phase alive" — a run inside its usage-limit wait shows zero here while
    # being perfectly healthy.
    $running = @(Get-Process claude -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Write-Host "  claude    : $($running.Count) process(es) on this machine, interactive sessions included" -ForegroundColor Green
    } else {
        Write-Host '  claude    : none running (a run waiting out a usage limit also looks like this)' -ForegroundColor DarkGray
    }
    Write-Host '  How far along, and how much longer:  phasekit dashboard' -ForegroundColor DarkGray
    Write-Host ''
}

function Write-LogHeader {
    param([System.IO.FileInfo] $File)
    Write-Host ''
    Write-Host ('-' * 72) -ForegroundColor DarkGray
    Write-Host "  $($File.Name)" -ForegroundColor Cyan
    Write-Host ('-' * 72) -ForegroundColor DarkGray
    Write-Host ''
}

function Get-NewestLog {
    param([string] $LogDir)
    Get-ChildItem -Path $LogDir -Filter '*.log' -ErrorAction SilentlyContinue |
        Sort-Object CreationTime -Descending | Select-Object -First 1
}

function Watch-Logs {
    <#
        Follows the run as it happens, across phases.

        `Get-Content -Wait` was not enough for an unattended sequence: it holds one file
        open, and the moment auto finishes a phase it starts writing a *new* log. The tail
        then sits on a file nobody is writing to any more, which looks exactly like a hung
        run — so you go and restart the follow by hand at every phase boundary.

        This reads by byte offset instead, and rolls over to any log created after the one
        it is on. It ends when the sequence does, by either marker auto leaves behind.
    #>
    param($Config)

    $stopFile = Join-Path $Config.logDir 'auto-stopped.txt'
    $doneFile = Join-Path $Config.logDir 'auto-finished.txt'
    $startedAt = Get-Date

    # What the sequence itself is doing, which no phase log records. Start from the end of
    # it, after showing the last few lines: somebody attaching mid-run wants to know where
    # the run is, not to replay it, and everything before this moment is already in the
    # phase logs the follower is about to show.
    $journal = Get-AutoJournalFile -Config $Config
    $journalAt = 0L
    if (Test-Path $journal) {
        $recent = @(Get-Content -LiteralPath $journal -Tail 6 -ErrorAction SilentlyContinue)
        if ($recent.Count -gt 0) {
            Write-Host ''
            Write-Host '  Where the sequence is:' -ForegroundColor Cyan
            foreach ($l in $recent) { Write-Host "  | $l" -ForegroundColor DarkCyan }
        }
        $journalAt = (Get-Item $journal).Length
    }

    # A detached launch gets here before the child has opened its first log.
    $current = Get-NewestLog -LogDir $Config.logDir
    while (-not $current) {
        Start-Sleep -Seconds 1
        if (((Get-Date) - $startedAt).TotalSeconds -gt 60) { Write-Host 'No log appeared in 60s — the run never started.' -ForegroundColor Red; return 1 }
        $current = Get-NewestLog -LogDir $Config.logDir
    }

    # Only the tail of the log already in progress; every later one from its first line,
    # because there is nothing to catch up on.
    $tail = 40
    $lastData = Get-Date
    $lastNotice = Get-Date

    while ($true) {
        Write-LogHeader -File $current
        $createdAt = $current.CreationTime

        Reset-StreamClock
        $fs = [System.IO.File]::Open($current.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                                     [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        # Stateful, so a UTF-8 character split across two reads still decodes.
        $decoder = [System.Text.Encoding]::UTF8.GetDecoder()
        $pending = ''
        $primed = $false
        $rollTo = $null

        try {
            while ($true) {
                $len = $fs.Length
                if ($fs.Position -lt $len) {
                    $count = [int][Math]::Min($len - $fs.Position, 1MB)
                    $bytes = New-Object byte[] $count
                    $read = $fs.Read($bytes, 0, $count)
                    if ($read -gt 0) {
                        $chars = New-Object char[] ($read)
                        $n = $decoder.GetChars($bytes, 0, $read, $chars, 0)
                        $pending += [string]::new($chars, 0, $n)

                        # The last piece has no newline yet: the writer is mid-line. Hold it
                        # back rather than rendering half an event.
                        $parts = $pending -split "`n"
                        $pending = $parts[-1]
                        $lines = @($parts[0..($parts.Count - 2)])

                        if (-not $primed -and $tail -gt 0 -and $lines.Count -gt $tail) {
                            $lines = $lines[($lines.Count - $tail)..($lines.Count - 1)]
                        }
                        foreach ($l in $lines) { Write-StreamLine -Line $l.TrimEnd("`r") }
                        if ($lines.Count -gt 0) { $lastData = Get-Date; $lastNotice = Get-Date }
                    }
                    $primed = $true
                    continue
                }

                $primed = $true

                # Caught up. Anything else to move to?
                $newest = Get-NewestLog -LogDir $Config.logDir
                if ($newest -and $newest.CreationTime -gt $createdAt) { $rollTo = $newest; break }

                foreach ($marker in @($stopFile, $doneFile)) {
                    if ((Test-Path $marker) -and (Get-Item $marker).LastWriteTime -gt $startedAt) {
                        Write-Host ''
                        Get-Content -LiteralPath $marker | ForEach-Object {
                            Write-Host "  $_" -ForegroundColor $(if ($marker -eq $doneFile) { 'Green' } else { 'Red' })
                        }
                        Write-Host ''
                        return $(if ($marker -eq $doneFile) { 0 } else { 1 })
                    }
                }

                # The gates, the merge and the push happen without the agent, so none of
                # them reach a phase log. The sequence writes them to its own journal, and
                # this is where they get shown: in the gap between one phase log ending and
                # the next one being created, which is exactly when they happen.
                if (Test-Path $journal) {
                    $jlen = (Get-Item $journal).Length
                    # A new sequence truncates it. Reading on from the old offset would
                    # start halfway through the first line of the new run.
                    if ($jlen -lt $journalAt) { $journalAt = 0 }
                    if ($jlen -gt $journalAt) {
                        $jfs = [System.IO.File]::Open($journal, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                                                      [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
                        try {
                            [void] $jfs.Seek($journalAt, [System.IO.SeekOrigin]::Begin)
                            $buf = New-Object byte[] ([int][Math]::Min($jlen - $journalAt, 256KB))
                            $n = $jfs.Read($buf, 0, $buf.Length)
                            $chunk = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
                            # Only up to the last newline: the writer may be mid-line, and
                            # half a line shown now is a whole line lost later.
                            $cut = $chunk.LastIndexOf([char] 10)
                            if ($cut -ge 0) {
                                $journalAt += ([System.Text.Encoding]::UTF8.GetByteCount($chunk.Substring(0, $cut + 1)))
                                foreach ($l in ($chunk.Substring(0, $cut) -split "`n")) {
                                    if ($l.Trim()) { Write-Host ("  | " + $l.TrimEnd([char] 13)) -ForegroundColor DarkCyan }
                                }
                                $lastData = Get-Date
                                $lastNotice = Get-Date
                            }
                        }
                        finally { $jfs.Dispose() }
                    }
                }

                # Silence is still possible - a usage-limit wait writes nothing anywhere.
                # Say so, so it does not read as a hang.
                $quiet = ((Get-Date) - $lastData).TotalMinutes
                if ($quiet -gt 3 -and ((Get-Date) - $lastNotice).TotalMinutes -gt 5) {
                    Write-Host ("  ... quiet for {0:N0} min - a usage-limit wait, or a gate that prints nothing until it ends" -f $quiet) -ForegroundColor DarkGray
                    $lastNotice = Get-Date
                }

                Start-Sleep -Seconds 1
            }
        } finally { $fs.Dispose() }

        $current = $rollTo
        $tail = 0
    }
}

function Invoke-Logs {
    $cfg = Get-PhaseKitConfig -Path $Config
    $script:StreamFull = [bool] $Full
    if ($Follow) { return (Watch-Logs -Config $cfg) }

    $newest = Get-NewestLog -LogDir $cfg.logDir
    if (-not $newest) { Write-Host 'No logs yet.'; return 0 }

    $age = [math]::Round(((Get-Date) - $newest.LastWriteTime).TotalMinutes)
    Write-Host ''
    Write-Host "  $($newest.Name)" -ForegroundColor Cyan
    Write-Host "  last written $($newest.LastWriteTime.ToString('HH:mm:ss'))  ($age min ago)" -ForegroundColor DarkGray
    if ($age -gt 5) {
        Write-Host '  Nothing has been written for a while - this run is finished, waiting out a usage limit, or dead.' -ForegroundColor Yellow
    }
    Write-Host ''

    # Rendered, not raw: the log is stream-json, and dumping it verbatim is what sends
    # people to `git log` instead.
    Get-Content -LiteralPath $newest.FullName -Tail 200 | ForEach-Object { Write-StreamLine -Line $_ }
    return 0
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

# Detaching forwards the same command minus -Detach, so the child does the real work.
if ($Detach -and -not $env:PHASEKIT_DETACHED) {
    $fwd = @($Command)
    if ($Phase) { $fwd += $Phase }
    foreach ($p in @('Text', 'File', 'Config', 'Model', 'Effort', 'Session')) {
        $v = Get-Variable -Name $p -ValueOnly -ErrorAction SilentlyContinue
        if ($v) { $fwd += @("-$p", $v) }
    }
    foreach ($p in @('MaxRetries', 'WaitMinutes')) {
        $v = Get-Variable -Name $p -ValueOnly -ErrorAction SilentlyContinue
        if ($v) { $fwd += @("-$p", "$v") }
    }
    if ($Targets) { $fwd += @('-Targets', ($Targets -join ',')) }
    if ($Push) { $fwd += '-Push' }
    if ($NoBranch) { $fwd += '-NoBranch' }
    if ((Start-Detached -ForwardArgs $fwd) -eq 1) { exit 1 }

    # The run is now independent of this terminal, so hand the terminal back to watching
    # it. Ctrl+C here stops the watching, never the run — which is the whole point of
    # detaching, and is worth saying out loud because the two look identical.
    if ($NoFollow) { exit 0 }
    Write-Host ''
    Write-Host '  Following the run. Ctrl+C stops the following, not the run.' -ForegroundColor DarkGray
    Write-Host '  Come back to it any time with:  phasekit logs -Follow' -ForegroundColor DarkGray
    $Follow = $true
    exit (Invoke-Logs)
}

# ---------------------------------------------------------------------------
# dashboard
# ---------------------------------------------------------------------------

function Get-ProgressBar {
    param([int] $Done, [int] $Total, [int] $Width)
    if ($Total -le 0) { return '' }
    $filled = [int] [Math]::Round($Width * $Done / $Total)
    if ($filled -gt $Width) { $filled = $Width }
    return (([string][char]0x2588) * $filled) + (([string][char]0x2591) * ($Width - $filled))
}

function Limit-Text {
    param([string] $Text, [int] $Width)
    if (-not $Text) { return '' }
    if ($Text.Length -le $Width) { return $Text }
    return $Text.Substring(0, [Math]::Max(1, $Width - 1)) + [string][char]0x2026
}

function Show-Spend {
    <#
        What each target has cost, read back out of the logs.

        Wall clock is what `dashboard` already answers, and on a subscription it is the
        wrong question: two targets that took the same afternoon can differ tenfold in
        what they spent, because the cost of a request is the size of the context it
        carries and a long session's context only grows. This is the view that makes a
        runaway target visible while there are still targets left to run.
    #>
    param($Config, [string[]] $Targets)

    $stats = Get-TargetLogStats -LogDir $Config.logDir

    # The sequence is the order worth reading this in, but it is not what makes a target
    # measurable - the log is. A project with no autoSequence, or one that has run targets
    # by hand, still has logs and still deserves an answer, so fall back to what the log
    # directory holds rather than to the error `auto` would rightly give.
    $sequence = @()
    try { $sequence = @(Get-AutoSequence -Config $Config -Targets $Targets) } catch { }
    if ($sequence.Count -eq 0) {
        $sequence = @($stats.Keys | Sort-Object { $stats[$_].first } |
                      ForEach-Object { [pscustomobject]@{ target = $_ } })
    }

    Write-Host ''
    Write-Host "  phasekit  $(Split-Path -Leaf $Config.codeDir) - what the sequence has spent" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  target   attempts  requests   peak ctx    weighted' -ForegroundColor DarkGray

    $total = [int64] 0
    $rows = 0
    foreach ($item in $sequence) {
        $name = $item.target -replace '[^\w.-]', '_'
        if (-not $stats.Contains($name)) { continue }

        # Every attempt, not just the last: a target restarted three times was paid for
        # three times, and reporting only the surviving log would flatter it.
        $spend = [pscustomobject]@{ requests = 0; peak = 0; weighted = 0 }
        foreach ($f in Get-ChildItem -Path $Config.logDir -Filter "phase-$name-*.log" -File -ErrorAction SilentlyContinue) {
            $one = Get-LogSpend -LogPath $f.FullName
            $spend.requests += $one.requests
            $spend.weighted += $one.weighted
            if ($one.peak -gt $spend.peak) { $spend.peak = $one.peak }
        }
        if ($spend.requests -eq 0) { continue }

        $total += $spend.weighted
        $rows++
        # Loud above half a million tokens of context: that is where a request costs three
        # times what the same request cost at the start of the same task.
        $colour = if ($spend.peak -ge 450000) { 'Yellow' } else { 'Gray' }
        Write-Host ('  {0,-8} {1,8} {2,9} {3,10} {4,11}' -f
            $item.target,
            $stats[$name].attempts,
            $spend.requests,
            ('{0}k' -f [math]::Round($spend.peak / 1000)),
            ('{0:N1}M' -f ($spend.weighted / 1e6))) -ForegroundColor $colour
    }

    Write-Host ''
    Write-Host ('  {0} targets measured, {1:N1}M in total, {2:N1}M each on average' -f
        $rows, ($total / 1e6), $(if ($rows) { $total / $rows / 1e6 } else { 0 })) -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  weighted: one unit is a full-price input token. A cached read counts a tenth,' -ForegroundColor DarkGray
    Write-Host '  writing the cache a quarter more, output five. Only the ratios are real -' -ForegroundColor DarkGray
    Write-Host '  the number is for putting two targets next to each other.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host "  context compacts at $($Config.autoCompact); a target that peaks far above it" -ForegroundColor DarkGray
    Write-Host '  was run before that ceiling existed.' -ForegroundColor DarkGray
    Write-Host ''
}

function Show-Dashboard {
    <#
        One screen, and it fits in one screen on purpose. Anything that needs scrolling is
        already `phasekit status` or `phasekit logs`; what belongs here is the three things
        somebody walking past the machine wants: how far, what now, how much longer.
    #>
    param([Parameter(Mandatory)] $Frame)

    $pct = if ($Frame.total -gt 0) { [int] [Math]::Round(100 * $Frame.doneCount / $Frame.total) } else { 0 }

    Write-Host ''
    Write-Host ("  phasekit  {0}" -f $Frame.name) -ForegroundColor Cyan -NoNewline
    Write-Host ("{0,$([Math]::Max(1, 62 - $Frame.name.Length))}" -f $Frame.now.ToString('dd/MM HH:mm')) -ForegroundColor DarkGray

    Write-Host ''
    Write-Host ('  ' + (Get-ProgressBar -Done $Frame.doneCount -Total $Frame.total -Width 50)) -ForegroundColor Green -NoNewline
    Write-Host ("   {0} / {1}   {2}%" -f $Frame.doneCount, $Frame.total, $pct)
    Write-Host ''

    # What is happening right now, which is the one line that changes between refreshes.
    $running = @($Frame.rows | Where-Object { $_.state -eq 'running' })
    $merging = @($Frame.rows | Where-Object { $_.state -eq 'merging' })
    $stalled = @($Frame.rows | Where-Object { $_.state -eq 'stalled' })
    if ($merging.Count -gt 0 -and $running.Count -eq 0) {
        # Committed, gates running, no log growing. Without this the longest gate in
        # the list outlives the quiet window and every successful merge reads as a
        # stall — which is how an alarm stops being read at all.
        foreach ($r in $merging) {
            Write-Host ('  now       ') -NoNewline
            Write-Host ("{0,-6}" -f $r.target) -ForegroundColor Cyan -NoNewline
            Write-Host ("{0,-44}" -f (Limit-Text $r.label 43)) -NoNewline
            Write-Host ("committed, merging" -f $r.commits) -ForegroundColor Green
            $spent = if ($r.context -gt 0) {
                ('   context {0}k' -f [math]::Round($r.context / 1000))
            } else { '' }
            Write-Host ("            on {0}{1}" -f (Format-ModelLabel -Model $r.model -Effort $r.effort -Separator " / effort "), $spent) -ForegroundColor DarkGray
        }
    }
    elseif ($running.Count -gt 0) {
        foreach ($r in $running) {
            $for = Format-Duration ($Frame.now - $r.latest).TotalMinutes
            Write-Host ('  now       ') -NoNewline
            Write-Host ("{0,-6}" -f $r.target) -ForegroundColor Cyan -NoNewline
            Write-Host ("{0,-44}" -f (Limit-Text $r.label 43)) -NoNewline
            Write-Host ("running {0}" -f $for) -ForegroundColor Green
            $spent = if ($r.context -gt 0) {
                ('   context {0}k' -f [math]::Round($r.context / 1000))
            } else { '' }
            Write-Host ("            on {0}{1}" -f (Format-ModelLabel -Model $r.model -Effort $r.effort -Separator " / effort "), $spent) -ForegroundColor DarkGray
        }
    }
    elseif ($stalled.Count -gt 0) {
        foreach ($r in $stalled) {
            $quiet = Format-Duration ($Frame.now - $r.last).TotalMinutes
            Write-Host ('  now       ') -NoNewline
            Write-Host ("{0,-6}" -f $r.target) -ForegroundColor Yellow -NoNewline
            Write-Host ("{0,-44}" -f (Limit-Text $r.label 43)) -NoNewline
            Write-Host ("quiet for {0}" -f $quiet) -ForegroundColor Yellow
            $spent = if ($r.context -gt 0) {
                ('   context {0}k' -f [math]::Round($r.context / 1000))
            } else { '' }
            Write-Host ("            on {0}{1}" -f (Format-ModelLabel -Model $r.model -Effort $r.effort -Separator " / effort "), $spent) -ForegroundColor DarkGray
        }
    }
    elseif ($Frame.remaining -gt 0) {
        Write-Host '  now       nothing running' -ForegroundColor DarkGray
    }

    # Everything above is inferred from files that outlive the process that wrote them,
    # so a sequence killed an hour ago and one merely between targets look identical up
    # to here. This is the line that tells them apart.
    $rn = $Frame.runner
    if ($rn -and -not $rn.alive) {
        if ($rn.here) {
            Write-Host ('  runner    no process — the runner was killed on {0}, it did not stop' -f $rn.target) -ForegroundColor Red
            Write-Host '            nothing else records this: restart with  phasekit auto -Push -Detach' -ForegroundColor Cyan
        }
        else {
            Write-Host ('  runner    marked as running on {0}, which is not this machine' -f $rn.machine) -ForegroundColor DarkGray
        }
    }
    elseif ($rn -and $rn.alive) {
        Write-Host ('  runner    process {0}, since {1}' -f $rn.pid, $rn.started.ToString('dd/MM HH:mm')) -ForegroundColor DarkGray
    }
    elseif ($Frame.live) {
        # Work is visibly happening and nothing claimed it. A runner started before this
        # mark existed, or one started some other way - either is fine, but saying "none"
        # over a target that is plainly running is the kind of wrong that gets a line
        # ignored forever after.
        Write-Host '  runner    unmarked — something is running that did not leave a mark' -ForegroundColor DarkGray
    }
    elseif ($Frame.remaining -gt 0 -and -not $Frame.finished) {
        Write-Host '  runner    none — no sequence is walking these targets' -ForegroundColor DarkGray
    }

    $next = @($Frame.rows | Where-Object { $_.state -eq 'queued' } | Select-Object -First 3 | ForEach-Object { $_.target })
    if ($next.Count -gt 0) {
        Write-Host ('  next      ' + ($next -join '  ')) -ForegroundColor DarkGray
    }

    # The estimate. Two numbers rather than one, because the gap between them IS the
    # answer: when they are close the sequence is running freely, and when they are a
    # factor of ten apart the thing to fix is the allowance, not the work.
    # What the sequence is spending, which is the other half of "how much longer": the
    # estimate below is in hours, and hours of an allowance are what the model and the
    # effort actually cost. A target that overrides either is named, because an
    # unexplained difference in the finished code usually traces back to one.
    $off = @($Frame.rows | Where-Object { $_.custom -and $_.state -ne 'done' })
    Write-Host ('  model     {0}' -f (Format-ModelLabel -Model $Frame.model -Effort $Frame.effort -Separator ' / effort ')) -ForegroundColor DarkGray -NoNewline
    if ($off.Count -gt 0) {
        $named = @($off | Select-Object -First 4 | ForEach-Object { '{0} {1}' -f $_.target, (Format-ModelLabel -Model $_.model -Effort $_.effort) })
        $more = if ($off.Count -gt 4) { ", +$($off.Count - 4)" } else { '' }
        Write-Host ('   except ' + ($named -join ', ') + $more) -ForegroundColor Yellow
    } else { Write-Host '' }

    $p = $Frame.pace
    if ($p.samples -gt 0) {
        Write-Host ''
        Write-Host ('  pace      typical target {0}   quickest quarter {1}   ({2} measured)' -f `
                    (Format-Duration $p.typicalMinutes), (Format-Duration $p.quickMinutes), $p.samples)
        if ($null -ne $p.observedMinutes) {
            Write-Host ('            {0} per target as it has actually gone, waits included' -f `
                        (Format-Duration $p.observedMinutes)) -ForegroundColor DarkGray
        }

        Write-Host ''
        if ($Frame.remaining -eq 0) {
            Write-Host '  left      nothing — every target in the sequence has landed' -ForegroundColor Green
        }
        else {
            $word = if ($Frame.remaining -eq 1) { 'target' } else { 'targets' }
            Write-Host ('  left      {0} {1}' -f $Frame.remaining, $word) -NoNewline
            Write-Host ('   ~{0} of work' -f (Format-Duration $p.workingLeft)) -ForegroundColor Green -NoNewline
            if ($null -ne $p.observedLeft) {
                Write-Host ('   ~{0} at the observed pace' -f (Format-Duration $p.observedLeft)) -ForegroundColor Yellow
            } else { Write-Host '' }
        }
    }

    foreach ($line in @(Format-ForecastLines -Forecast $Frame.forecast)) {
        Write-Host $line.text -ForegroundColor $line.colour
    }

    if ($Frame.started) {
        Write-Host ('  since     {0}   ({1} elapsed)' -f $Frame.started.ToString('dd/MM HH:mm'), (Format-Duration $Frame.elapsed)) -ForegroundColor DarkGray
    }

    # Per phase, so a long sequence reads as a shape rather than a number.
    Write-Host ''
    $line = '  '
    foreach ($ph in $Frame.phases) {
        $cell = '{0} {1} {2}/{3}   ' -f $ph.phase, (Get-ProgressBar -Done $ph.done -Total $ph.total -Width $ph.total), $ph.done, $ph.total
        if (($line.Length + $cell.Length) -gt 78) { Write-Host $line.TrimEnd(); $line = '  ' }
        $line += $cell
    }
    if ($line.Trim()) { Write-Host $line.TrimEnd() }

    Write-Host ''
    Write-Host '            what each phase and target is:  phasekit steps' -ForegroundColor DarkGray

    if ($Frame.finished) {
        Write-Host ''
        Write-Host '  FINISHED  the sequence walked every target it was given.' -ForegroundColor Green
    }

    if ($Frame.stop) {
        Write-Host ''
        $why = @($Frame.stop.text | Where-Object { $_ -match '^Why:' } | Select-Object -First 1)
        $text = if ($why) { $why[0] } else { 'see auto-stopped.txt' }
        if ($Frame.stop.stale) {
            Write-Host ('  note      a stop marker from {0} is still lying around, but work has ' -f $Frame.stop.when.ToString('dd/MM HH:mm')) -ForegroundColor DarkGray
            Write-Host '            happened since — the next sequence clears it.' -ForegroundColor DarkGray
        }
        else {
            Write-Host ('  STOPPED   {0}  {1}' -f $Frame.stop.when.ToString('dd/MM HH:mm'), (Limit-Text $text 60)) -ForegroundColor Red
            Write-Host ('            full reason: {0}' -f (Join-Path $Frame.logDir 'auto-stopped.txt')) -ForegroundColor DarkGray
        }
    }

    Write-Host ''
}

function Get-StepMark {
    <#
        One character for the state, in a column, so a long plan reads down the left edge
        rather than by reading every line.
    #>
    param([string] $State)
    switch ($State) {
        'done'    { return @{ mark = 'x'; colour = 'Green' } }
        'running' { return @{ mark = '>'; colour = 'Cyan' } }
        'merging' { return @{ mark = '>'; colour = 'Cyan' } }
        'stalled' { return @{ mark = '!'; colour = 'Yellow' } }
        default   { return @{ mark = ' '; colour = 'Gray' } }
    }
}

function Show-Steps {
    <#
        The sequence written out: every phase with its title, every target inside it with
        its own, and for the work that has not happened yet the sentence the plan opens it
        with.

        The dashboard answers "how far and how long". This answers the other question
        somebody has while watching it — what IS G.2, and why is it after phase D — and it
        answers it from the plan itself rather than from a second description that would
        drift. Nobody should have to open a two-thousand-line file to find out what the
        target on screen is about.

        Summaries are printed for what is still ahead, not for what has landed. A finished
        target's rationale is in the git history and in the plan; on this screen it would
        push the part that still matters off the bottom.
    #>
    param(
        [Parameter(Mandatory)] $Frame,
        [string] $Only
    )

    $rows = @($Frame.rows)
    if ($Only) {
        $rows = @($rows | Where-Object { $_.target -eq $Only -or ($_.target -split '\.')[0] -eq $Only })
        if ($rows.Count -eq 0) {
            Write-Host ''
            Write-Host "  Nothing in the sequence matches '$Only'." -ForegroundColor Yellow
            Write-Host '  Try a phase (G) or a target (G.2), or run  phasekit steps  for all of them.' -ForegroundColor DarkGray
            Write-Host ''
            return
        }
    }

    Write-Host ''
    Write-Host ("  phasekit  {0} — the plan, step by step" -f $Frame.name) -ForegroundColor Cyan
    Write-Host ''

    # One target asked for by name gets its whole section, because that is the only way to
    # ask "what does this task actually say" without opening the file.
    if ($Only -and $Only -match '\.' -and $rows.Count -eq 1) {
        $t = $Frame.outline.targets[$rows[0].target]
        $state = $rows[0].state
        Write-Host ("  {0}  {1}" -f $rows[0].target, $(if ($t) { $t.title } else { $rows[0].label })) -ForegroundColor Cyan
        Write-Host ("  {0}" -f $state) -ForegroundColor DarkGray
        Write-Host ''
        if ($t) {
            # The blank line under the heading is markdown's, not the author's.
            $body = @($t.body)
            while ($body.Count -gt 0 -and -not $body[0].Trim()) { $body = $body[1..($body.Count - 1)] }
            while ($body.Count -gt 0 -and -not $body[-1].Trim()) { $body = $body[0..($body.Count - 2)] }
            foreach ($line in $body) { Write-Host ("  {0}" -f $line) }
        }
        else { Write-Host '  The plan has no section for this target — it is in the sequence but not written up.' -ForegroundColor Yellow }
        Write-Host ''
        return
    }

    $seen = @{}
    foreach ($row in $rows) {
        $key = ($row.target -split '\.')[0]
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $ph = @($Frame.phases | Where-Object { $_.phase -eq $key })[0]
            $title = if ($ph -and $ph.title) { $ph.title } else { '' }
            Write-Host ''
            Write-Host ("  PHASE {0}" -f $key) -ForegroundColor Cyan -NoNewline
            Write-Host ("  {0}" -f $title) -NoNewline
            if ($ph) {
                $pad = [Math]::Max(1, 66 - 8 - $key.Length - $title.Length)
                Write-Host ("{0,$pad}{1}/{2}" -f '', $ph.done, $ph.total) -ForegroundColor DarkGray
            } else { Write-Host '' }
        }

        $m = Get-StepMark -State $row.state
        Write-Host ("    [{0}] " -f $m.mark) -ForegroundColor $m.colour -NoNewline
        Write-Host ("{0,-6}" -f $row.target) -ForegroundColor $m.colour -NoNewline
        Write-Host (Limit-Text $row.label 64)

        if ($row.state -ne 'done' -and $row.about) {
            foreach ($chunk in (Split-Wrapped -Text $row.about -Width 62)) {
                Write-Host ("           {0}" -f $chunk) -ForegroundColor DarkGray
            }
        }

        # The note on a sequence entry is the trap its author already knew about. It
        # belongs next to the target, not in a config file nobody opens.
        if ($row.note) {
            $first = $true
            foreach ($chunk in (Split-Wrapped -Text $row.note -Width 56)) {
                Write-Host ("           {0}{1}" -f $(if ($first) { 'note: ' } else { '      ' }), $chunk) -ForegroundColor Yellow
                $first = $false
            }
        }
    }

    Write-Host ''
    Write-Host '  [x] landed   [>] running   [!] quiet   [ ] not started' -ForegroundColor DarkGray
    Write-Host '  One target in full:  phasekit steps G.2' -ForegroundColor DarkGray
    Write-Host ''
}

function Split-Wrapped {
    <#
        Wraps at word boundaries. A summary is a sentence, and a sentence cut at a fixed
        column stops being one.
    #>
    param([string] $Text, [int] $Width)

    $out = @()
    $line = ''
    foreach ($word in ($Text -split '\s+')) {
        if (-not $word) { continue }
        if ($line -and ($line.Length + 1 + $word.Length) -gt $Width) { $out += $line; $line = $word }
        else { $line = if ($line) { "$line $word" } else { $word } }
    }
    if ($line) { $out += $line }
    return $out
}

function Invoke-Steps {
    <#
        `phasekit steps` with no argument writes out the whole sequence; with a phase or a
        target it narrows to that. It reads the same frame the dashboard does, so the two
        can never disagree about what is running.
    #>
    $cfg = Get-PhaseKitConfig -Path $Config
    $frame = Get-DashboardFrame -Config $cfg -Targets $Targets
    Show-Steps -Frame $frame -Only $Phase
    return 0
}

function Invoke-Forecast {
    <#
        When the sequence ends, with the usage limits in the picture: the work left, walked
        through the five-hour and the weekly windows as the logs have measured them. It
        assumes the machine stays on and nothing waits for a person. -Json prints the same
        estimate for another tool to read.
    #>
    $cfg = Get-PhaseKitConfig -Path $Config
    $frame = Get-DashboardFrame -Config $cfg -Targets $Targets
    if ($Json) {
        $summary = ConvertTo-ForecastSummary -Forecast $frame.forecast
        $summary['remaining'] = $frame.remaining
        $summary['total'] = $frame.total
        # Straight to stdout: anything left on the pipeline would become this function's
        # return value, and `exit` would swallow it.
        [Console]::Out.WriteLine(($summary | ConvertTo-Json -Depth 4))
        return 0
    }

    Write-Host ''
    if ($frame.remaining -eq 0) {
        Write-Host '  Nothing left: every target in the sequence has landed.' -ForegroundColor Green
        Write-Host ''
        return 0
    }
    $lines = @(Format-ForecastLines -Forecast $frame.forecast)
    if ($lines.Count -eq 0) {
        Write-Host '  No estimate yet: no finished target has a priced log to measure.' -ForegroundColor Yellow
        Write-Host ''
        return 0
    }
    Write-Host ('  left      {0} of {1} targets' -f $frame.remaining, $frame.total)
    foreach ($line in $lines) { Write-Host $line.text -ForegroundColor $line.colour }
    $f = $frame.forecast
    Write-Host ('            from the last {0} targets; {1} of work at the typical pace, {2} waits for a reset' -f `
                $f.samples, (Format-Duration $f.typical.workMinutes), $f.typical.waits) -ForegroundColor DarkGray
    Write-Host '            assumes the machine stays on and no stop waits for a person' -ForegroundColor DarkGray
    Write-Host ''
    return 0
}

function Invoke-Spend {
    <#
        `phasekit spend`. Reads every log in full, so it is slower than the dashboard and
        deliberately not part of it.
    #>
    $cfg = Get-PhaseKitConfig -Path $Config
    Show-Spend -Config $cfg -Targets $Targets
    return 0
}

function Invoke-Dashboard {
    <#
        How far the sequence has got, what it is doing now, and roughly how much is left.

        Everything on it is read fresh from the repository, the plan and the logs. The
        dashboard writes nothing and remembers nothing, so it is equally honest about a
        run it never saw start, one that died without saying so, and a target somebody
        finished by hand between sequences.
    #>
    $cfg = Get-PhaseKitConfig -Path $Config

    # Pin the resolved path. The walk-up search starts from the current directory, and a
    # watch that re-read by name would find a different config if anything moved.
    $configPath = $cfg.configPath

    while ($true) {
        # `auto` re-reads autoSequence on every iteration, because a sequence can grow
        # while it is being walked. A watch that read it once keeps drawing the list as it
        # stood hours ago and quietly disagrees with the runner about how much is left —
        # which is the one number somebody leaves this on screen for.
        if ($Watch) {
            # A half-written config is a normal thing to catch mid-save. Keep the last
            # good one rather than dying on somebody's open editor.
            try { $cfg = Get-PhaseKitConfig -Path $configPath } catch { }
        }

        $frame = Get-DashboardFrame -Config $cfg -Targets $Targets
        $frame | Add-Member -NotePropertyName logDir -NotePropertyValue $cfg.logDir -Force

        # Clearing the screen needs a real console. Redirected to a file or through a
        # pipe there is no cursor to move, and Clear-Host takes the whole command down
        # with it on the very first frame — so a redirected watch scrolls instead.
        if ($Watch) { try { Clear-Host } catch { Write-Host '' } }
        Show-Dashboard -Frame $frame

        if (-not $Watch) { break }
        Write-Host ('  refreshing every {0}s — Ctrl+C to stop watching, which stops nothing else.' -f $script:DashboardRefresh) -ForegroundColor DarkGray
        Start-Sleep -Seconds $script:DashboardRefresh
    }

    return 0
}

function Invoke-Pause {
    <#
        Stops the sequence now and keeps it stopped - across a reboot, the logon task and
        the watchdog - until `phasekit resume`. For the laptop going into a bag: the
        branch, the files on disk and the conversation all stay, and a resume carries on
        the same target in the same conversation, the way it does after a power cut.
    #>
    $cfg = Get-PhaseKitConfig -Path $Config
    $runner = Get-RunnerState -Config $cfg
    $already = Get-PauseState -Config $cfg
    Write-Host ''

    if ($runner -and $runner.alive) {
        Set-PauseState -Config $cfg -Target $runner.target -Command (Get-ProcessCommandLine -Id $runner.pid)
        Stop-ProcessTree -Id $runner.pid
        # A command the agent sent to the background hangs from a shell that has already
        # exited, so the tree above never reached it - and it keeps the ports the next
        # gate needs.
        $orphans = if ($runner.started) {
            @(Get-OrphanedWork -Since $runner.started -Dirs @($cfg.codeDir, $cfg.codeDir.Replace('\', '/')))
        } else { @() }
        foreach ($o in $orphans) { Stop-ProcessTree -Id ([int] $o.ProcessId) }
        if ($orphans.Count) {
            Write-Host "  Also stopped $($orphans.Count) process tree(s) it had left running in the background." -ForegroundColor DarkGray
        }
        # Deliberate, so it must not read as a killed run - that is the one thing the
        # watchdog restarts.
        Remove-Item -LiteralPath (Get-RunnerFile -Config $cfg) -ErrorAction SilentlyContinue
        $line = '{0}  PAUSED at {1} - phasekit resume carries on' -f (Get-Date -Format 'HH:mm:ss'), $runner.target
        Add-Content -LiteralPath (Get-AutoJournalFile -Config $cfg) -Value $line -ErrorAction SilentlyContinue
        Write-Host "  Paused at $($runner.target). The runner (process $($runner.pid)) and everything it started are stopped." -ForegroundColor Green
    }
    elseif ($already) {
        $where = if ($already.target) { " at $($already.target)" } else { '' }
        Write-Host "  Already paused$where. Nothing restarts it until:  phasekit resume" -ForegroundColor Yellow
        Write-Host ''
        return 0
    }
    else {
        # Nothing running now, but the logon task or the watchdog could start it later -
        # a dead runner's mark is exactly what the watchdog restarts. The marker holds them.
        Set-PauseState -Config $cfg -Target $(if ($runner) { $runner.target } else { '' }) -Command ''
        Remove-Item -LiteralPath (Get-RunnerFile -Config $cfg) -ErrorAction SilentlyContinue
        Write-Host '  No sequence is running. It is paused anyway, so nothing starts it on its own.' -ForegroundColor Green
    }

    Write-Host '  Nothing is lost: the branch, the files on disk and the conversation stay as they are.' -ForegroundColor DarkGray
    Write-Host '  Safe to close the lid or shut down. To carry on:  phasekit resume' -ForegroundColor Cyan
    Write-Host ''
    return 0
}

function Invoke-Resume {
    <#
        Ends a pause and starts the sequence again, detached. The target it stopped on is
        picked up the way `auto` picks up any unfinished one: its conversation, resumed
        over the work on its branch.
    #>
    $cfg = Get-PhaseKitConfig -Path $Config
    Write-Host ''

    $runner = Get-RunnerState -Config $cfg
    if ($runner -and $runner.alive) {
        Write-Host "  The sequence is already running - process $($runner.pid), on $($runner.target)." -ForegroundColor Yellow
        Write-Host ''
        return 0
    }

    $pause = Get-PauseState -Config $cfg
    if (Remove-StaleGitLock -RepoDir $cfg.codeDir) {
        Write-Host '  Removed a .git/index.lock left by the stopped run.' -ForegroundColor DarkGray
    }
    Remove-Item -LiteralPath (Get-PauseFile -Config $cfg) -ErrorAction SilentlyContinue

    # Through the logon task when there is one for this sequence: it parents the runner to
    # the scheduler, so the run survives the terminal - and the session - that typed this.
    $task = if ($IsWindows) { Get-ScheduledTask -TaskName 'phasekit-resume' -ErrorAction SilentlyContinue } else { $null }
    if ($task -and ([string] $task.Actions[0].Arguments).Contains($cfg.configPath)) {
        Start-ScheduledTask -TaskName 'phasekit-resume'
        $how = 'the phasekit-resume task'
    }
    elseif ($pause -and (Split-CommandLineArgs -CommandLine $pause.command)) {
        $argLine = Split-CommandLineArgs -CommandLine $pause.command
        $env:PHASEKIT_DETACHED = '1'
        try {
            if ($IsWindows) { Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argLine -WindowStyle Hidden | Out-Null }
            else { Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argLine | Out-Null }
        }
        finally { $env:PHASEKIT_DETACHED = $null }
        $how = 'the command the paused runner was started with'
    }
    else {
        Write-Host '  The pause is lifted, but nothing records how this sequence was started. Start it as usual:' -ForegroundColor Yellow
        Write-Host '    phasekit auto -Push -Detach' -ForegroundColor Cyan
        Write-Host ''
        return 1
    }

    # The task detaches once more before the runner announces itself, so give it a moment
    # rather than reporting a start that simply has not happened yet.
    $deadline = (Get-Date).AddSeconds(40)
    do {
        Start-Sleep -Seconds 2
        $runner = Get-RunnerState -Config $cfg
    } while (-not ($runner -and $runner.alive) -and (Get-Date) -lt $deadline)

    if ($runner -and $runner.alive) {
        Write-Host "  Resumed through $how - process $($runner.pid), on $($runner.target)." -ForegroundColor Green
        Write-Host '  Watch it:  phasekit dashboard -Watch' -ForegroundColor DarkGray
        Write-Host ''
        return 0
    }
    Write-Host "  Started through $how, but no runner has announced itself yet." -ForegroundColor Yellow
    Write-Host '  Check  phasekit status  in a minute; the journal is logs/auto-progress.log.' -ForegroundColor DarkGray
    Write-Host ''
    return 1
}

function Write-LintFindings {
    param($Findings)
    foreach ($f in @($Findings)) {
        $colour = if ($f.level -eq 'error') { 'Red' } else { 'Yellow' }
        Write-Host ("  {0,-7}  {1,-24} {2}" -f $f.level.ToUpperInvariant(), $f.where, $f.message) -ForegroundColor $colour
    }
}

function Invoke-Lint {
    <#
        `phasekit lint`: the plan checked mechanically, no model, nothing changed. Exit 1
        when there is an error.
    #>
    try { $cfg = Get-PhaseKitConfig -Path $Config }
    catch {
        Write-Host ''
        Write-Host "  ERROR    phasekit.json            $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ''
        return 1
    }
    $findings = @(Test-PlanLint -Config $cfg)
    $errors = @($findings | Where-Object level -eq 'error')
    $warnings = @($findings | Where-Object level -eq 'warning')
    Write-Host ''
    Write-LintFindings $findings
    if ($findings.Count) { Write-Host '' }
    $tasks = @(Get-Content -LiteralPath $cfg.plan -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*- \[( |x|X)\]\s+[A-Za-z0-9]+\.\d+\b' }).Count
    if ($errors.Count) {
        Write-Host "  $($errors.Count) error(s), $($warnings.Count) warning(s). Fix the errors before running the plan." -ForegroundColor Red
        Write-Host ''
        return 1
    }
    Write-Host "  The plan checks out: $tasks task(s), $($warnings.Count) warning(s)." -ForegroundColor Green
    Write-Host ''
    return 0
}

function Invoke-Draft {
    <#
        `phasekit draft`: an interactive Claude session that interviews you and writes the
        plan, the prompts, the agent rules and phasekit.json in phasekit's format, then
        lints them. It talks in your language and writes the files in English. -Text gives
        it a first description of what you want.
    #>
    $templates = Join-Path $root 'templates'
    $prompt = (Get-Content -LiteralPath (Join-Path $templates 'DRAFT.md') -Raw)
    $seed = if ($Text) { "`nWhat the person wants, in their own words, to start from:`n$($Text.Trim())`n" } else { '' }
    $prompt = $prompt.Replace('{{PROJECT}}', (Get-Location).Path).Replace('{{PHASEKIT}}', $root).
        Replace('{{TODAY}}', (Get-Date -Format 'yyyy-MM-dd')).Replace('{{SEED}}', $seed)

    if ($DryRun) {
        Write-Host ''
        Write-Host '--- prompt ---' -ForegroundColor Cyan
        Write-Host $prompt
        return 0
    }
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        throw 'claude is not on PATH. Install Claude Code first: https://claude.com/claude-code'
    }
    Write-Host ''
    Write-Host '  Starting an interactive session that will interview you and write the plan.' -ForegroundColor Cyan
    Write-Host '  Answer in any language; the files are written in English. /exit when you are done.' -ForegroundColor DarkGray
    Write-Host ''
    # Interactive on purpose: a plan is a conversation, and the person's answers are the
    # part no model can supply.
    & claude $prompt
    return $LASTEXITCODE
}

function Invoke-Lessons {
    <#
        `phasekit lessons` lists what the agents learned; `add` records one by hand (an
        answer you gave to a stop is often one), `drop <id>` retires one. Hand-added
        lessons come from "owner" and follow the same rules as the agents' own.
    #>
    $cfg = Get-PhaseKitConfig -Path $Config
    $sub = if ($Phase) { $Phase.ToLowerInvariant() } else { 'list' }

    switch ($sub) {
        'add' {
            if ($File) { $Text = Get-Content -LiteralPath $File -Raw }
            if (-not $Text) { throw 'What lesson? phasekit lessons add -Text "when <condition> | <lesson> | evidence: <what shows it>"' }
            $parsed = ConvertFrom-LessonOps -Text ("LESSONS`nADD: " + $Text.Trim())
            if (@($parsed.ops).Count -eq 0) {
                foreach ($r in $parsed.rejected) { Write-Host "  Not added: $($r.why)" -ForegroundColor Red }
                return 1
            }
            $max = [int] $cfg.lessonsMax
            $r = Invoke-WithLessonLock -Config $cfg -Action {
                $read = Read-LessonStore -Config $cfg
                if (-not $read.ok) { throw $read.why }
                $out = Update-LessonStore -Store $read.store -Ops @($parsed.ops) -Source 'owner' -Max $max
                Save-LessonStore -Config $cfg -Store $read.store
                $out
            }
            foreach ($d in $r.done) { Write-Host "  $d" -ForegroundColor Green }
            foreach ($d in $r.refused) { Write-Host "  refused: $d" -ForegroundColor Yellow }
            return 0
        }
        'drop' {
            if (-not $Item) { throw 'Which lesson? e.g.  phasekit lessons drop L3' }
            $id = $Item.ToUpperInvariant()
            $why = if ($Text) { "dropped by hand: $Text" } else { 'dropped by hand' }
            $found = Invoke-WithLessonLock -Config $cfg -Action {
                $read = Read-LessonStore -Config $cfg
                if (-not $read.ok) { throw $read.why }
                $l = @($read.store.lessons) | Where-Object { $_ -and $_['id'] -eq $id } | Select-Object -First 1
                if (-not $l) { return $false }
                $read.store.lessons = @(@($read.store.lessons) | Where-Object { $_ -and $_['id'] -ne $id })
                $l['retired'] = (Get-Date).ToString('yyyy-MM-dd HH:mm'); $l['why'] = $why
                $read.store.retired = @(@($read.store.retired) + $l | Where-Object { $_ } | Select-Object -Last 100)
                Save-LessonStore -Config $cfg -Store $read.store
                return $true
            }
            if ($found) { Write-Host "  $id retired." -ForegroundColor Green; return 0 }
            Write-Host "  No lesson $id." -ForegroundColor Yellow
            return 1
        }
        default {
            $read = Read-LessonStore -Config $cfg
            Write-Host ''
            if (-not $read.ok) { Write-Host "  $($read.why)" -ForegroundColor Red; return 1 }
            if (-not $cfg.lessons) { Write-Host '  Lessons are off ("lessons": false in phasekit.json): agents are not told them.' -ForegroundColor Yellow }
            $ranked = @($read.store.lessons | Where-Object { $_ } |
                Sort-Object @{ e = { [int] $_['score'] }; Descending = $true }, @{ e = { [string] $_['added'] }; Descending = $true })
            if ($ranked.Count -eq 0) { Write-Host '  No lessons yet.' -ForegroundColor DarkGray }
            foreach ($l in $ranked) {
                Write-Host ("  {0,-4} score {1,-2} from {2,-8} added {3}" -f $l['id'], $l['score'], $l['from'], $l['added']) -ForegroundColor Cyan
                Write-Host "       when $($l['when'])"
                Write-Host "       $($l['lesson'])"
                Write-Host "       evidence: $($l['evidence'])" -ForegroundColor DarkGray
                if (@($l['confirmedBy']).Count) { Write-Host "       confirmed by: $(@($l['confirmedBy']) -join ', ')" -ForegroundColor DarkGray }
            }
            Write-Host ''
            Write-Host "  $($ranked.Count) kept (cap $($cfg.lessonsMax)), $(@($read.store.retired).Count) retired.  $(Get-LessonsFile -Config $cfg)" -ForegroundColor DarkGray
            Write-Host ''
            return 0
        }
    }
}

function Invoke-Account {
    <#
        `phasekit account` lists the accounts; `phasekit account <name>` or `next`
        switches the one runs use. Needs no phasekit.json: accounts belong to the
        machine, not to a project.
    #>
    if ($Phase) {
        $picked = Set-ActiveAccount -Name $Phase
        # Choosing an account by hand vouches for it: a login renewed, or a limit known to
        # be over. Its record no longer keeps automatic switches away from it.
        if ((Read-AccountLimits).ContainsKey($picked.name)) {
            Set-AccountLimited -Name $picked.name -Until (Get-Date).AddMinutes(-1)
        }
        Write-Host ''
        Write-Host "  Runs now use account $($picked.name)  ($($picked.dir))" -ForegroundColor Green
        if ($IsWindows -and -not (Test-Path (Join-Path $picked.dir '.credentials.json'))) {
            Write-Host "  No login found there. Log in once:  `$env:CLAUDE_CONFIG_DIR='$($picked.dir)'; claude   then /login" -ForegroundColor Yellow
        }
        Write-Host '  A run waiting out a usage limit resumes within a minute; a conversation already' -ForegroundColor DarkGray
        Write-Host '  working keeps its account until it stops. Interactive sessions are not affected.' -ForegroundColor DarkGray
        Write-Host ''
        return 0
    }

    $active = Get-ActiveAccount
    $accounts = @(Get-ClaudeAccounts)
    $limits = Read-AccountLimits
    Write-Host ''
    if ($accounts.Count -eq 0) { Write-Host "  No Claude account found in $(Get-AccountsHome) (.claude, .claude-<name>)." -ForegroundColor Yellow }
    foreach ($a in $accounts) {
        $isActive = $a.dir.TrimEnd('\', '/') -ieq $active.dir.TrimEnd('\', '/')
        $mark = if ($isActive) { '*' } else { ' ' }
        $how = if (-not $isActive) { '' }
               elseif ($active.chosen) { '   <- runs use this (chosen with phasekit account)' }
               else { '   <- runs use this (CLAUDE_CONFIG_DIR)' }
        $spent = if ($limits.ContainsKey($a.name) -and $limits[$a.name] -gt (Get-Date)) {
            "   (allowance spent, back ~$($limits[$a.name].ToString('ddd HH:mm')))"
        } else { '' }
        Write-Host ("  {0} {1,-8} {2}{3}{4}" -f $mark, $a.name, $a.dir, $how, $spent) -ForegroundColor $(if ($isActive) { 'Green' } else { 'White' })
    }
    Write-Host ''
    Write-Host '  Switch:  phasekit account <name>    or    phasekit account next' -ForegroundColor DarkGray
    Write-Host ''
    return 0
}

switch ($Command.ToLowerInvariant()) {
    'init' { Invoke-Init; exit 0 }
    'account' { exit (Invoke-Account) }
    'pause' { exit (Invoke-Pause) }
    'resume' { exit (Invoke-Resume) }
    'merge' { exit (Invoke-Merge) }
    'check' {
        # The merge preconditions, reported and nothing else. Safe to run at any time,
        # including while a phase is still going.
        $cfg = Get-PhaseKitConfig -Path $Config
        if (-not $Phase) { throw 'Which phase? e.g.  phasekit check 0' }
        $r = Test-PhaseReady -Config $cfg -Phase $Phase
        Write-Host ''
        if ($r.ok) { Write-Host "  Phase $Phase is ready to merge (gates not run — use 'phasekit merge')." -ForegroundColor Green }
        else { foreach ($p in $r.problems) { Write-Host "  BLOCKED  $p" -ForegroundColor Yellow } }
        Write-Host ''
        exit ($(if ($r.ok) { 0 } else { 1 }))
    }
    'run' { Set-MachineAwake; try { exit (Invoke-Run -Mode 'run') } finally { Set-MachineAwake -Off } }
    'reply' { Set-MachineAwake; try { exit (Invoke-Run -Mode 'reply') } finally { Set-MachineAwake -Off } }
    'continue' { Set-MachineAwake; try { exit (Invoke-Run -Mode 'continue') } finally { Set-MachineAwake -Off } }
    'finish' { Set-MachineAwake; try { exit (Invoke-Run -Mode 'finish') } finally { Set-MachineAwake -Off } }
    'status' { Invoke-Status; exit 0 }
    'dashboard' { exit (Invoke-Dashboard) }
    'dash' { exit (Invoke-Dashboard) }
    'steps' { exit (Invoke-Steps) }
    'spend' { exit (Invoke-Spend) }
    'forecast' { exit (Invoke-Forecast) }
    'plan' { exit (Invoke-Steps) }
    'gates' {
        $cfg = Get-PhaseKitConfig -Path $Config
        Write-Host ''
        $failed = Invoke-Gates -Config $cfg
        Write-Host ''
        if ($failed -eq 0) { Write-Host 'All gates green.' -ForegroundColor Green; exit 0 }
        Write-Host "$failed gate(s) failing." -ForegroundColor Red
        exit 1
    }
    # Held for the whole sequence, gates and merges included, and released however it
    # ends. An unattended run is not idle, whatever the power settings think.
    'auto' { Set-MachineAwake; try { exit (Invoke-Auto) } finally { Set-MachineAwake -Off } }
    'logs' { exit (Invoke-Logs) }
    'lessons' { exit (Invoke-Lessons) }
    'lint' { exit (Invoke-Lint) }
    'draft' { exit (Invoke-Draft) }
    'models' {
        # Which model and effort each target of the sequence will run on, and why. Not $item:
        # at this level that is the script's own -Item parameter, typed [string], and a
        # sequence entry assigned to it becomes an empty string.
        $cfg = Get-PhaseKitConfig -Path $Config
        Write-Host ''
        foreach ($entry in @(Get-AutoSequence -Config $cfg)) {
            $p = Resolve-TargetModel -Config $cfg -Item $entry
            $done = Test-TargetDone -Config $cfg -Target $entry.target -AllowNoCommits:$entry.allowNoCommits
            $colour = if ($done) { 'DarkGray' } else { 'White' }
            Write-Host ("  {0,-8} {1,-34} {2}" -f $entry.target, (Format-ModelLabel -Model $p.model -Effort $p.effort), $p.source) -ForegroundColor $colour
        }
        Write-Host ''
        $reviewers = (@($cfg.reviewModels) | ForEach-Object { Format-ModelLabel -Model $_ -Effort $cfg.reviewEffort }) -join ', '
        Write-Host ("  review: {0}   fixRounds: {1}   switchAccounts: {2}   limitFallback: {3}" -f $(if ($cfg.review) { $reviewers } else { 'off' }),
            $(if (@($cfg.fixRounds).Count) { $cfg.fixRounds -join ', ' } else { 'none' }),
            $(if ($cfg.switchAccounts) { 'on' } else { 'off' }),
            $(if (@($cfg.limitFallback).Count) { $cfg.limitFallback -join ', ' } else { 'none (wait for the reset)' })) -ForegroundColor DarkGray
        Write-Host ''
        exit 0
    }
    'review' {
        # The reviewer on demand, on a branch as it stands. Changes nothing; prints the
        # verdict and the findings.
        if (-not $Phase) { throw 'Which target? e.g.  phasekit review 4.2' }
        $cfg = Initialize-Run -ForPhase $Phase
        Set-MachineAwake
        try { $r = Invoke-Review -Config $cfg -Target $Phase } finally { Set-MachineAwake -Off }
        Write-Host ''
        if ($r.findings) { Write-Host $r.findings; Write-Host '' }
        exit ($(if ($r.verdict -eq 'PASS') { 0 } else { 1 }))
    }
    default { Show-Help; exit 0 }
}
