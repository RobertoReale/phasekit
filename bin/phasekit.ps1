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
  phasekit gates                   run the project's gates locally, no agent
  phasekit auto [-Push]            walk autoSequence unattended: run, verify, merge, next
  phasekit logs [-Follow]          show or tail the newest run log

Options
  -Detach          run in a process that survives this terminal closing
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
    return @(
        '--permission-mode', 'bypassPermissions'
        '--model', $Config.model
        '--effort', $Config.effort
        '--output-format', 'stream-json'
        '--verbose'
    )
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

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (& $quote $PSCommandPath)) +
               ($ForwardArgs | ForEach-Object { & $quote $_ })

    $env:PHASEKIT_DETACHED = '1'
    $proc = Start-Process -FilePath $pwsh -ArgumentList $argList -WindowStyle Hidden -PassThru
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
    if ($exists) { git -C $Config.codeDir checkout $branch | Out-Null }
    else { git -C $Config.codeDir checkout -b $branch | Out-Null }

    $base = (git -C $Config.codeDir rev-parse HEAD).Trim()
    Set-Content -LiteralPath (Join-Path $Config.logDir ("phase-{0}.base" -f ($Phase -replace '[^\w.-]', '_'))) -Value $base
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
                if (-not (Test-Path $File)) { throw "Answer file not found: $File" }
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

    # Branch handling only for a fresh run: reply and continue join work already in flight,
    # where a dirty tree is expected rather than a reason to refuse.
    $branch = if ($Mode -eq 'run') { Assert-CleanTreeAndBranch -Config $cfg -Phase $Phase } else { $null }

    $log = New-LogPath -Config $cfg -Phase $Phase

    Write-Host ''
    Write-Host "  $(Split-Path -Leaf $cfg.plan) — phase $Phase  ($Mode)" -ForegroundColor Cyan
    Write-Host "  Working dir : $($cfg.workingDir)"
    Write-Host "  Code repo   : $($cfg.codeDir)"
    if ($branch) { Write-Host "  Branch      : $($branch.name)" }
    if ($script:SessionId) { Write-Host "  Session     : $($script:SessionId)" }
    Write-Host "  Model       : $($cfg.model) / effort $($cfg.effort)"
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
    param([switch] $Quiet)

    if (-not $Phase) { throw 'Which phase? e.g.  phasekit merge 0' }

    $cfg = Get-PhaseKitConfig -Path $Config
    $main = Get-MainBranch -Config $cfg
    $report = Test-PhaseReady -Config $cfg -Phase $Phase

    Write-Host ''
    Write-Host "  Merging $($report.branch) into $main" -ForegroundColor Cyan
    Write-Host ''

    foreach ($p in $report.problems) { Write-Host "  BLOCKED  $p" -ForegroundColor Red }

    if ($report.commits.Count -gt 0) {
        Write-Host "  $($report.commits.Count) commit(s) on the branch:" -ForegroundColor Cyan
        foreach ($c in $report.commits) { Write-Host "    $c" }
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
    Remove-Item -LiteralPath $stopFile -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host "  Unattended sequence — $($sequence.Count) target(s)" -ForegroundColor Cyan
    foreach ($s in $sequence) {
        $m = if ($s.model) { $s.model } else { $cfg.model }
        $done = Test-TargetDone -Config $cfg -Target $s.target
        $mark = if ($done) { 'done' } else { '    ' }
        Write-Host ("    [{0}] {1,-6} {2}{3}" -f $mark, $s.target, $m, $(if ($s.note) { "   ($($s.note))" } else { '' }))
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
        Write-Host ''
        Write-Host "STOPPED at $Target" -ForegroundColor Red
        Write-Host "  $Why" -ForegroundColor Red
        Write-Host "  $Next" -ForegroundColor Cyan
        Write-Host "  Written to: $stopFile"
    }

    foreach ($item in $sequence) {
        $target = $item.target
        if ($item.model) { $Model = $item.model } else { $Model = $null }

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

        # -DryRun prints each target's prompt and stops there. Verifying and merging a
        # run that never happened would report every target as broken.
        if ($DryRun) { Invoke-Run -Mode 'run' | Out-Null; continue }

        $exit = @(Invoke-Run -Mode 'run')[-1]

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

        $report = Test-PhaseReady -Config $cfg -Phase $target
        if (-not $report.ok) {
            Stop-Auto -Target $target `
                -Why ($report.problems -join '; ') `
                -Next "Read the log, then:  phasekit reply $target -File answer.txt   (or  phasekit continue $target)"
            return 1
        }

        # Last element, not the whole thing: if any callee ever leaks to the output stream
        # again, this reads the exit code rather than the noise in front of it.
        $merged = @(Invoke-Merge -Quiet)[-1]
        if ($merged -ne 0) {
            Stop-Auto -Target $target -Why 'the merge preconditions or the gates failed on the branch' `
                -Next "phasekit merge $target   to see what blocked it"
            return 1
        }

        if ($Push) {
            git -C $cfg.codeDir push | Out-Host
            if ($LASTEXITCODE -ne 0) {
                Stop-Auto -Target $target -Why 'push failed' -Next 'push by hand, then rerun phasekit auto'
                return 1
            }
        }
    }

    Write-Host ''
    Write-Host 'Sequence complete. Every target ran, verified and merged.' -ForegroundColor Green
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
    Write-Host ''
}

function Invoke-Logs {
    $cfg = Get-PhaseKitConfig -Path $Config
    $logs = Get-ChildItem -Path $cfg.logDir -Filter '*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    if (-not $logs) { Write-Host 'No logs yet.'; return }

    $newest = $logs[0]
    $age = [math]::Round(((Get-Date) - $newest.LastWriteTime).TotalMinutes)
    Write-Host ''
    Write-Host "  $($newest.Name)" -ForegroundColor Cyan
    Write-Host "  last written $($newest.LastWriteTime.ToString('HH:mm:ss'))  ($age min ago)" -ForegroundColor DarkGray
    if ($age -gt 5 -and -not $Follow) {
        Write-Host '  Nothing has been written for a while — this run is finished, waiting out a usage limit, or dead.' -ForegroundColor Yellow
    }
    Write-Host ''

    # Rendered, not raw: the log is stream-json, and dumping it verbatim is what sends
    # people to `git log` instead.
    if ($Follow) { Get-Content -LiteralPath $newest.FullName -Tail 40 -Wait | ForEach-Object { Write-StreamLine -Line $_ } }
    else { Get-Content -LiteralPath $newest.FullName -Tail 200 | ForEach-Object { Write-StreamLine -Line $_ } }
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
    Start-Detached -ForwardArgs $fwd
    exit 0
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
    'run' { exit (Invoke-Run -Mode 'run') }
    'reply' { exit (Invoke-Run -Mode 'reply') }
    'continue' { exit (Invoke-Run -Mode 'continue') }
    'status' { Invoke-Status; exit 0 }
    'gates' {
        $cfg = Get-PhaseKitConfig -Path $Config
        Write-Host ''
        $failed = Invoke-Gates -Config $cfg
        Write-Host ''
        if ($failed -eq 0) { Write-Host 'All gates green.' -ForegroundColor Green; exit 0 }
        Write-Host "$failed gate(s) failing." -ForegroundColor Red
        exit 1
    }
    'auto' { exit (Invoke-Auto) }
    'logs' { Invoke-Logs; exit 0 }
    default { Show-Help; exit 0 }
}
