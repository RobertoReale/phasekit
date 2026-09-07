#Requires -Version 7.0
<#
.SYNOPSIS
    Register a repeating task that restarts a phasekit sequence whose runner was killed.

.DESCRIPTION
    resume-at-logon covers the reboot: the machine comes back, somebody logs on, the
    sequence carries on. It cannot cover the death that happens while the machine stays
    up and nobody logs on again for three days - the runner is killed, the mark stays on
    disk, and the sequence sits there untouched until the owner comes home.

    This asks the same question every quarter of an hour instead of once at logon.

    What it may act on is deliberately narrow. A sequence that finished, and a sequence
    that stopped because something needs a person, both clear the runner mark on the way
    out; only a killed process leaves one behind. So a mark whose process is gone is the
    single case that gets a restart, and a stop that was asking a question is left alone
    to keep asking it.

    Restarting is safe to repeat: `auto` skips targets that are ticked and merged, resumes
    a pinned session rather than redoing it, and refuses to start at all if it finds a
    live runner. Three restarts inside three hours, though, is a fault that a fourth will
    not fix - it gives up there, says so on the desktop, and writes down what it saw.

    Registers under the current user, no elevation, no stored password: the run needs that
    user's session, PATH and git credentials, and so does the check.

.EXAMPLE
    tools/watchdog.ps1 -Install -Push -Config C:\work\notes\phasekit.json
    tools/watchdog.ps1 -Status -Config C:\work\notes\phasekit.json
    tools/watchdog.ps1 -Once -Config C:\work\notes\phasekit.json
    tools/watchdog.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [switch] $Install,
    [switch] $Uninstall,
    [switch] $Status,

    # Perform one check now. This is what the scheduled task calls, and running it by
    # hand is how to see what the task will do without waiting for it.
    [switch] $Once,

    # The phasekit.json of the sequence to watch. Required with -Install and -Once.
    [string] $Config,

    # Passed through to `phasekit auto` when it restarts one.
    [switch] $Push,

    [string] $TaskName = 'phasekit-watchdog',

    # Long enough that a restart is not the first answer to a blip, short enough that a
    # night's work is not lost to a death at midnight.
    [int] $EveryMinutes = 15,

    [int] $MaxRestarts = 3,
    [int] $WindowMinutes = 180
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$phasekit = Join-Path $root 'bin' 'phasekit.ps1'

if (-not $IsWindows -and ($Install -or $Uninstall -or $Status)) {
    Write-Host ''
    Write-Host 'Registering the check is Task Scheduler here, and this is not Windows.' -ForegroundColor Yellow
    Write-Host 'The check itself is portable - drive it from cron or a systemd timer:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  */15 * * * *  pwsh -NoProfile -File $PSCommandPath -Once -Config <config>" -ForegroundColor Cyan
    Write-Host ''
    exit 1
}

function Get-Task { Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
# The check
# ---------------------------------------------------------------------------

if ($Once) {
    if (-not $Config) { throw 'Which sequence? Pass -Config path\to\phasekit.json' }
    . (Join-Path $root 'lib' 'PhaseKit.ps1')
    $cfg = Get-PhaseKitConfig -Path (Resolve-Path $Config).Path

    $verdict = Invoke-WatchdogCheck -Config $cfg -MaxRestarts $MaxRestarts -WindowMinutes $WindowMinutes
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'

    # Only the two verdicts that mean something are written down. A line every quarter of
    # an hour saying the sequence is fine is a log nobody can find anything in.
    if ($verdict.action -in @('restart', 'given-up')) {
        Add-Content -LiteralPath (Join-Path $cfg.logDir 'watchdog.log') `
            -Value ("{0}  {1,-9} {2}" -f $stamp, $verdict.action, $verdict.why)
    }

    switch ($verdict.action) {
        'restart' {
            Write-Host "$stamp  restarting: $($verdict.why)" -ForegroundColor Yellow
            $argv = @('auto')
            if ($Push) { $argv += '-Push' }
            $argv += @('-Detach', '-NoFollow', '-Config', $cfg.configPath)
            & $phasekit @argv
        }
        'given-up' {
            # Written once, next to the stop note a runner would have left, so whoever
            # comes back finds the reason in the place they already look.
            $note = Join-Path $cfg.logDir 'watchdog-gave-up.txt'
            if (-not (Test-Path $note)) {
                Set-Content -LiteralPath $note -Value @"
The watchdog stopped restarting this sequence
$stamp

Why: $($verdict.why)
Last target: $($verdict.target)

Something is killing the runner rather than stopping it, so starting it again would
spend a session to arrive at the same place. Read the newest log in this directory,
fix what it names, then:

  phasekit auto -Push -Detach

Delete this file to let the watchdog try again.
"@
                if (Get-Command Send-PhaseKitNotice -ErrorAction SilentlyContinue) {
                    Send-PhaseKitNotice -Kind 'stop' -Title 'phasekit: the watchdog gave up' `
                        -Message "The runner keeps being killed on $($verdict.target). See watchdog-gave-up.txt."
                }
            }
            Write-Host "$stamp  given up: $($verdict.why)" -ForegroundColor Red
        }
        default { Write-Host "$stamp  $($verdict.action): $($verdict.why)" -ForegroundColor DarkGray }
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Registering it
# ---------------------------------------------------------------------------

if ($Status) {
    $t = Get-Task
    if (-not $t) { Write-Host "Not registered ($TaskName)." -ForegroundColor Yellow }
    else {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        Write-Host ''
        Write-Host "  $TaskName" -ForegroundColor Cyan
        Write-Host "  State     : $($t.State)"
        Write-Host "  Last run  : $($info.LastRunTime)  (result $($info.LastTaskResult))"
        Write-Host "  Next run  : $($info.NextRunTime)"
    }

    if ($Config) {
        . (Join-Path $root 'lib' 'PhaseKit.ps1')
        $cfg = Get-PhaseKitConfig -Path (Resolve-Path $Config).Path
        $state = Get-RunnerState -Config $cfg
        $where = if (-not $state) { 'nothing running' }
                 elseif ($state.alive) { "alive - process $($state.pid) on $($state.target)" }
                 elseif (-not $state.here) { "a mark left by $($state.machine)" }
                 else { "DEAD - process $($state.pid) died on $($state.target)" }
        Write-Host "  Sequence  : $where"
        $log = Join-Path $cfg.logDir 'watchdog.log'
        if (Test-Path $log) {
            Write-Host ''
            Write-Host '  What it has done:' -ForegroundColor Cyan
            Get-Content -LiteralPath $log -Tail 5 | ForEach-Object { Write-Host "    $_" }
        }
    }
    Write-Host ''
    exit 0
}

if ($Uninstall) {
    if (-not (Get-Task)) { Write-Host "Nothing to remove ($TaskName)." -ForegroundColor Yellow; exit 0 }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed $TaskName." -ForegroundColor Green
    exit 0
}

if (-not $Install) { Write-Host 'Pass -Install, -Uninstall, -Status or -Once.'; exit 1 }
if (-not $Config) { throw 'Which sequence? Pass -Config path\to\phasekit.json' }

$Config = (Resolve-Path $Config).Path
. (Join-Path $root 'lib' 'PhaseKit.ps1')
$cfg = Get-PhaseKitConfig -Path $Config

$pushArg = if ($Push) { ' -Push' } else { '' }
$action = New-ScheduledTaskAction -Execute (Get-Process -Id $PID).Path `
    -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" " +
               "-Once$pushArg -MaxRestarts $MaxRestarts -WindowMinutes $WindowMinutes -Config `"$Config`"") `
    -WorkingDirectory $cfg.workingDir

# Ten years rather than [TimeSpan]::MaxValue: the sentinel is rejected by some builds of
# the scheduler, and a task that failed to register is worse than one that expires after
# the machine has been replaced twice.
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

if (Get-Task) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Description 'Restarts a phasekit sequence whose runner was killed. Ignores one that finished or stopped on purpose.' | Out-Null

Write-Host ''
Write-Host "Registered $TaskName." -ForegroundColor Green
Write-Host "  Runs      : every $EveryMinutes min, while $env:USERNAME is logged on"
Write-Host "  Sequence  : $Config"
Write-Host "  Restarts  : only a runner that was killed, at most $MaxRestarts in $WindowMinutes min"
Write-Host ''
Write-Host "See it:     tools/watchdog.ps1 -Status -Config `"$Config`"" -ForegroundColor Cyan
Write-Host "Remove it:  tools/watchdog.ps1 -Uninstall" -ForegroundColor Cyan
