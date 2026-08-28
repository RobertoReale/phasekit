#Requires -Version 7.0
<#
.SYNOPSIS
    Register a logon task that resumes an unfinished phasekit sequence.

.DESCRIPTION
    Everything else in phasekit survives inside the running process: a usage limit is
    waited out, a dropped connection is retried, a suspended machine no longer loses the
    wait. None of that helps when the process itself dies — a reboot, a power cut, Task
    Manager. A dead process cannot restart itself, so the restart has to come from
    outside it, and at logon is the only moment that reliably arrives.

    Resuming is safe to repeat. `auto` skips targets that are ticked *and* merged, and a
    target with a pinned session and a branch is resumed rather than restarted, so a
    half-finished task carries on from where it stopped instead of being redone.

    The task does nothing once the sequence has finished: auto-finished.txt is the guard,
    so this does not spawn a run at every logon for the rest of the machine's life.

    Registers under the current user, no elevation, no stored password. It runs only when
    that user is logged on — which is what you want, since the run needs their session,
    their PATH and their git credentials.

.EXAMPLE
    tools/resume-at-logon.ps1 -Install -Config C:\work\notes\phasekit.json
    tools/resume-at-logon.ps1 -Status
    tools/resume-at-logon.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [switch] $Install,
    [switch] $Uninstall,
    [switch] $Status,

    # The phasekit.json of the sequence to resume. Required with -Install.
    [string] $Config,

    # Passed through to `phasekit auto`.
    [switch] $Push,

    [string] $TaskName = 'phasekit-resume',

    # Long enough for the network and the credential manager to be up. A run that starts
    # before them fails on its first push and stops the sequence.
    [int] $DelayMinutes = 2
)

$ErrorActionPreference = 'Stop'
$phasekit = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin' 'phasekit.ps1'

# Task Scheduler is the Windows answer to "run this when the machine comes back". The
# other platforms have their own, and they are different enough that wrapping all three
# behind one script would hide which one you actually got. Say so and point at the
# equivalent, rather than failing on a missing cmdlet three lines further down.
if (-not $IsWindows) {
    Write-Host ''
    Write-Host 'This registers a Windows Task Scheduler task, and this is not Windows.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'The equivalent, with the same guard so it does nothing once the sequence has finished:'
    Write-Host ''
    Write-Host '  macOS   — a launchd agent with RunAtLoad, in ~/Library/LaunchAgents'
    Write-Host '  Linux   — a systemd --user unit with WantedBy=default.target,'
    Write-Host '            or  @reboot  in crontab'
    Write-Host ''
    Write-Host 'The command either should run, with your own paths:'
    Write-Host ''
    Write-Host '  pwsh -NoProfile -Command "if (Test-Path <logDir>/auto-finished.txt) { exit 0 };' -ForegroundColor Cyan
    Write-Host '                            & <phasekit>/bin/phasekit.ps1 auto -Push -Detach -NoFollow -Config <config>"' -ForegroundColor Cyan
    Write-Host ''
    exit 1
}

function Get-Task { Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue }

if ($Status) {
    $t = Get-Task
    if (-not $t) { Write-Host "Not registered ($TaskName)." -ForegroundColor Yellow; exit 0 }
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Host ''
    Write-Host "  $TaskName" -ForegroundColor Cyan
    Write-Host "  State     : $($t.State)"
    Write-Host "  Last run  : $($info.LastRunTime)  (result $($info.LastTaskResult))"
    Write-Host "  Action    : $($t.Actions[0].Execute) $($t.Actions[0].Arguments)"
    Write-Host ''
    exit 0
}

if ($Uninstall) {
    if (-not (Get-Task)) { Write-Host "Nothing to remove ($TaskName)." -ForegroundColor Yellow; exit 0 }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed $TaskName." -ForegroundColor Green
    exit 0
}

if (-not $Install) { Write-Host 'Pass -Install, -Uninstall or -Status.'; exit 1 }
if (-not $Config) { throw 'Which sequence? Pass -Config path\to\phasekit.json' }

$Config = (Resolve-Path $Config).Path
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib' 'PhaseKit.ps1')
$cfg = Get-PhaseKitConfig -Path $Config
$doneFile = Join-Path $cfg.logDir 'auto-finished.txt'

# Single-quoted PowerShell literals, so a path with spaces or a $ in it survives the trip
# through Task Scheduler's single argument string.
$q = { param($s) "'" + ($s -replace "'", "''") + "'" }
$pushArg = if ($Push) { ' -Push' } else { '' }
$inner = "if (Test-Path $(& $q $doneFile)) { exit 0 }; & $(& $q $phasekit) auto$pushArg -Detach -NoFollow -Config $(& $q $Config)"

$action = New-ScheduledTaskAction -Execute (Get-Process -Id $PID).Path `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$($inner -replace '"', '\"')`"" `
    -WorkingDirectory $cfg.workingDir

$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$trigger.Delay = "PT${DelayMinutes}M"

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew

if (Get-Task) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Description 'Resumes an unfinished phasekit sequence after a reboot. Does nothing once it has finished.' | Out-Null

Write-Host ''
Write-Host "Registered $TaskName." -ForegroundColor Green
Write-Host "  Runs      : at logon of $env:USERNAME, after $DelayMinutes min"
Write-Host "  Sequence  : $Config"
Write-Host "  Stops when: $doneFile exists"
Write-Host ''
Write-Host "Remove it:  tools/resume-at-logon.ps1 -Uninstall" -ForegroundColor Cyan
