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

    # dashboard: redraw every few seconds instead of printing once and returning.
    [switch] $Watch,

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
  phasekit run <phase>             execute one phase on its own branch
  phasekit reply <phase> -Text .   answer a question, in the same conversation
  phasekit reply <phase> -File .   the same, reading the answer from a file
  phasekit continue <phase>        pick up a phase that was interrupted
  phasekit check <phase>           are the merge preconditions met? changes nothing
  phasekit merge <phase>           verify, show the commits, then merge into main
  phasekit status [<phase>]        branch, commits, dirty files, pinned session
  phasekit dashboard [-Watch]      how far along, what is running, how much is left
  phasekit steps [G|G.2]           what every phase and target is, in the plan's words
  phasekit spend                   what each target cost: requests, peak context, weight
  phasekit gates                   run the project's gates locally, no agent
  phasekit auto [-Push]            walk autoSequence unattended: run, verify, merge, next
  phasekit logs [-Follow]          follow the run, rolling over as each phase starts

Options
  -Detach          run in a process that survives this terminal closing, then follow it
  -Watch           dashboard: redraw every 20s instead of printing once
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
        exit 1
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
    param([string] $Mode)   # 'run' | 'reply' | 'continue'

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
    }

    if ($DryRun) {
        Write-Host ''
        Write-Host '--- prompt ---' -ForegroundColor Cyan
        Write-Host $prompt
        Write-Host '--- command ---' -ForegroundColor Cyan
        Write-Host "claude $($first -join ' ')"
        return 0
    }

    # A fresh run demands a clean tree and creates the branch. Reply and continue join work
    # already in flight, where a dirty tree is the work — but they still have to be on the
    # right branch, which after a reboot they are not.
    $branch = if ($Mode -eq 'run') { Assert-CleanTreeAndBranch -Config $cfg -Phase $Phase }
              else { Restore-PhaseBranch -Config $cfg -Phase $Phase }

    $log = New-LogPath -Config $cfg -Phase $Phase

    Write-Host ''
    Write-Host "  $(Split-Path -Leaf $cfg.plan) — phase $Phase  ($Mode)" -ForegroundColor Cyan
    Write-Host "  Working dir : $($cfg.workingDir)"
    Write-Host "  Code repo   : $($cfg.codeDir)"
    if ($branch) { Write-Host "  Branch      : $($branch.name)" }
    if ($script:SessionId) { Write-Host "  Session     : $($script:SessionId)" }
    Write-Host "  Model       : $($cfg.model) / effort $($cfg.effort)"
    Write-Host "  Context     : compacts at $($cfg.autoCompact)"
    Write-Host "  Log         : $log"
    Write-Host "  Usage limit : wait $($cfg.waitMinutes) min, resume, up to $($cfg.maxRetries) times."
    Write-Host ''

    $exit = Invoke-AgentWithLimitRetry -Config $cfg -Phase $Phase -FirstArgs $first `
        -LogPath $log -SessionFile $sessionFile -Common $common

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
    Write-Host '  Gates:' -ForegroundColor Cyan
    $failed = Invoke-Gates -Config $cfg
    Write-Host ''

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

    $sequence = Get-AutoSequence -Config $cfg -Targets $Targets
    $stopFile = Join-Path $cfg.logDir 'auto-stopped.txt'
    $doneFile = Join-Path $cfg.logDir 'auto-finished.txt'
    # Both markers are how a follower knows the sequence ended, and why. A stale one from
    # the last sequence would end the next follow the moment it started.
    Remove-Item -LiteralPath $stopFile -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $doneFile -ErrorAction SilentlyContinue

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
        $done = Test-TargetDone -Config $cfg -Target $s.target -Snapshot $listing
        $mark = if ($done) { 'done' } else { '    ' }
        Write-Host ("    [{0}] {1,-6} {2}/{3}{4}" -f $mark, $s.target, $m, $e, $(if ($s.note) { "   ($($s.note))" } else { '' }))
    }
    Write-Host ''
    if ($Push) { Write-Host '  Pushing after each merge.' -ForegroundColor Yellow }

    function Stop-Auto {
        param([string] $Target, [string] $Why, [string] $Next)
        $text = @"
Unattended sequence stopped at $Target
$(Get-Date -Format 'yyyy-MM-dd HH:mm')

Why: $Why

What to do: $Next
"@
        Set-Content -LiteralPath $stopFile -Value $text
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
        $Model = if ($item.model) { $item.model } else { $cliModel }
        $Effort = if ($item.effort) { $item.effort } else { $cliEffort }

        if (Test-TargetDone -Config $cfg -Target $target) {
            Write-Host "  $target already done — skipping." -ForegroundColor DarkGray
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

        $started = (Test-Path $sessionFile) -and $branchExists -and ($ownCommits -gt 0 -or $treeDirty)
        if ($started) {
            $evidence = if ($ownCommits -gt 0) { "$ownCommits commit(s) on the branch" }
                        else { 'uncommitted work on disk' }
            Write-Host "  $target was already started ($evidence) - resuming that session, not restarting the phase." -ForegroundColor Yellow
        }
        elseif (Test-Path $sessionFile) {
            # Drop the pin: leaving it would make the next run take this same wrong turn,
            # and there is no session worth keeping behind a branch with nothing on it.
            Write-Host "  $target left a session behind but committed nothing - starting it fresh." -ForegroundColor Yellow
            Remove-Item -LiteralPath $sessionFile -Force -ErrorAction SilentlyContinue
        }

        $exit = @(Invoke-Run -Mode $(if ($started) { 'continue' } else { 'run' }))[-1]

        # Usage limits are already handled inside the run. What reaches here is a question,
        # a crash, or a dropped connection. Only the last of those is worth retrying: a
        # question survives any number of resumes and just gets re-asked, so it stops the
        # sequence — which is correct, because it needs a person.
        $tries = 0
        while ($exit -ne 0 -and $tries -lt 5) {
            $logNow = Get-ChildItem -Path $cfg.logDir -Filter "phase-$($target -replace '[^\w.-]', '_')-*.log" |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $tail = if ($logNow) { (Get-Content -LiteralPath $logNow.FullName -Tail 40) -join "`n" } else { '' }

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
            $exit = @(Invoke-Run -Mode 'continue')[-1]
        }

        # A run can end non-zero after its work already landed — the usual way is a runner
        # killed between the merge and the next target. Verifying then reports "not on the
        # phase branch", which is true, describes a success, and is written to
        # auto-stopped.txt in the words of a failure. Ask the outcome, not the exit code.
        if (Test-TargetDone -Config $cfg -Target $target) {
            Write-Host "  $target landed and merged despite exit $exit - moving on." -ForegroundColor DarkGray
            continue
        }

        $report = Test-PhaseReady -Config $cfg -Phase $target -AllowNoCommits:$item.allowNoCommits
        if (-not $report.ok) {
            Stop-Auto -Target $target `
                -Why ($report.problems -join '; ') `
                -Next ("Read the log, then answer in the same conversation:`n" +
                       "    phasekit reply $target -Text `"your answer`"`n" +
                       "  ...or -File <path> for a long one, or  phasekit continue $target  to just carry on.")
            return 1
        }

        # Last element, not the whole thing: if any callee ever leaks to the output stream
        # again, this reads the exit code rather than the noise in front of it.
        $merged = @(Invoke-Merge -Quiet -AllowNoCommits:$item.allowNoCommits)[-1]
        if ($merged -ne 0) {
            Stop-Auto -Target $target -Why 'the merge preconditions or the gates failed on the branch' `
                -Next "phasekit merge $target   to see what blocked it"
            return 1
        }

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
        }
    }

    Set-Content -LiteralPath $doneFile -Value @"
Unattended sequence complete
$(Get-Date -Format 'yyyy-MM-dd HH:mm')

Every target ran, verified and merged.
"@
    Clear-RunnerMark -Config $cfg
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

                # Silence is normal here — gates, a merge, or a usage-limit wait, none of
                # which write to the log. Say so, so it does not read as a hang.
                $quiet = ((Get-Date) - $lastData).TotalMinutes
                if ($quiet -gt 3 -and ((Get-Date) - $lastNotice).TotalMinutes -gt 5) {
                    Write-Host ("  ... quiet for {0:N0} min - gates, a merge, or waiting out a usage limit" -f $quiet) -ForegroundColor DarkGray
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
    $sequence = Get-AutoSequence -Config $Config -Targets $Targets

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
            Write-Host ("            on {0} / effort {1}{2}" -f $r.model, $r.effort, $spent) -ForegroundColor DarkGray
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
            Write-Host ("            on {0} / effort {1}{2}" -f $r.model, $r.effort, $spent) -ForegroundColor DarkGray
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
            Write-Host ("            on {0} / effort {1}{2}" -f $r.model, $r.effort, $spent) -ForegroundColor DarkGray
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
    Write-Host ('  model     {0} / effort {1}' -f $Frame.model, $Frame.effort) -ForegroundColor DarkGray -NoNewline
    if ($off.Count -gt 0) {
        $named = @($off | Select-Object -First 4 | ForEach-Object { '{0} {1}/{2}' -f $_.target, $_.model, $_.effort })
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

switch ($Command.ToLowerInvariant()) {
    'init' { Invoke-Init; exit 0 }
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
    'status' { Invoke-Status; exit 0 }
    'dashboard' { exit (Invoke-Dashboard) }
    'dash' { exit (Invoke-Dashboard) }
    'steps' { exit (Invoke-Steps) }
    'spend' { exit (Invoke-Spend) }
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
    default { Show-Help; exit 0 }
}
