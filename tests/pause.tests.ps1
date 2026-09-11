<#
    Pausing a sequence: the marker every automatic start honours, stopping a runner with
    everything it started, and what a resume needs to start the same runner again.

        pwsh -NoProfile -File tests/pause.tests.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'lib' 'PhaseKit.ps1')

$fails = 0
function Test-Case($name, $got, $expected) {
    $ok = ([string] $got) -eq ([string] $expected)
    if (-not $ok) { $script:fails++ }
    $mark = if ($ok) { 'ok  ' } else { 'FAIL' }
    $colour = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  {0}  {1,-56} {2}" -f $mark, $name, $(if ($ok) { '' } else { "got '$got', expected '$expected'" })) -ForegroundColor $colour
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("phasekit-pause-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
$cfg = [pscustomobject]@{ logDir = (Join-Path $root 'logs') }

try {
    Write-Host 'the marker'
    Test-Case 'no marker, not paused' ($null -eq (Get-PauseState -Config $cfg)) $true

    Set-PauseState -Config $cfg -Target 'L.1' -Command '"C:\Program Files\PowerShell\7\pwsh.exe" -File x.ps1 auto'
    $p = Get-PauseState -Config $cfg
    Test-Case 'the target it stopped on' $p.target 'L.1'
    Test-Case 'the command that started the runner' $p.command '"C:\Program Files\PowerShell\7\pwsh.exe" -File x.ps1 auto'
    Test-Case 'and when' ($null -ne $p.since) $true

    Set-Content -LiteralPath (Get-PauseFile -Config $cfg) -Value '{ half a fi'
    $p = Get-PauseState -Config $cfg
    Test-Case 'an unreadable marker still holds the sequence' ($null -ne $p) $true
    Test-Case 'without inventing a target' $p.target ''

    Write-Host 'relaunching the same runner'
    Test-Case 'quoted executable' (Split-CommandLineArgs '"C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -File "C:\a b\phasekit.ps1" auto -Push') '-NoProfile -File "C:\a b\phasekit.ps1" auto -Push'
    Test-Case 'bare executable' (Split-CommandLineArgs 'pwsh -NoProfile -File p.ps1 auto') '-NoProfile -File p.ps1 auto'
    Test-Case 'an executable alone has no arguments' (Split-CommandLineArgs 'pwsh') ''
    Test-Case 'nothing recorded, nothing to relaunch' (Split-CommandLineArgs '') ''

    Write-Host 'a stale git lock'
    $repo = Join-Path $root 'repo'
    New-Item -ItemType Directory -Force -Path (Join-Path $repo '.git') | Out-Null
    Test-Case 'no lock, nothing removed' (Remove-StaleGitLock -RepoDir $repo -GitRunning $false) $false
    Set-Content -LiteralPath (Join-Path $repo '.git' 'index.lock') -Value ''
    Test-Case 'a live git owns its lock' (Remove-StaleGitLock -RepoDir $repo -GitRunning $true) $false
    Test-Case 'so it is left alone' (Test-Path (Join-Path $repo '.git' 'index.lock')) $true
    Test-Case 'with no git running, the lock goes' (Remove-StaleGitLock -RepoDir $repo -GitRunning $false) $true
    Test-Case 'and is gone' (Test-Path (Join-Path $repo '.git' 'index.lock')) $false

    Write-Host 'stopping a runner stops what it started'
    # A child that starts a grandchild, like a runner starting claude starting a gate. The
    # grandchild writes its pid, so the test knows what has to disappear.
    $pwsh = (Get-Process -Id $PID).Path
    $pidFile = Join-Path $root 'grandchild.pid'
    $inner = "`$g = Start-Process -FilePath '$pwsh' -ArgumentList '-NoProfile','-Command','Start-Sleep 120' -PassThru" +
             $(if ($IsWindows) { ' -WindowStyle Hidden' } else { '' }) +
             "; Set-Content -LiteralPath '$pidFile' -Value `$g.Id; Start-Sleep 120"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
    $childArgs = @('-NoProfile', '-EncodedCommand', $encoded)
    $child = if ($IsWindows) { Start-Process -FilePath $pwsh -ArgumentList $childArgs -PassThru -WindowStyle Hidden }
             else { Start-Process -FilePath $pwsh -ArgumentList $childArgs -PassThru }

    $deadline = (Get-Date).AddSeconds(30)
    while (-not (Test-Path $pidFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
    $grandchild = [int] (Get-Content -LiteralPath $pidFile -TotalCount 1)
    Test-Case 'the grandchild is running before the stop' ([bool] (Get-Process -Id $grandchild -ErrorAction SilentlyContinue)) $true

    Stop-ProcessTree -Id $child.Id
    Start-Sleep -Seconds 2
    Test-Case 'the runner is stopped' ([bool] (Get-Process -Id $child.Id -ErrorAction SilentlyContinue)) $false
    Test-Case 'and so is what it started' ([bool] (Get-Process -Id $grandchild -ErrorAction SilentlyContinue)) $false

    Write-Host 'what the runner left in the background'
    $t0 = [datetime] '2026-09-11 17:00'
    $proj = 'C:\work\repo'
    $row = { param($id, $parent, $name, $minutes, $cmd)
             [pscustomobject]@{ ProcessId = $id; ParentProcessId = $parent; Name = $name
                                CreationDate = $t0.AddMinutes($minutes); CommandLine = $cmd } }
    $table = @(
        & $row 10 1 'explorer.exe' -600 'explorer.exe'
        # still held by a live parent: the runner's own tree, not an orphan
        & $row 20 10 'pwsh.exe' 5 'pwsh -File phasekit.ps1 auto'
        & $row 21 20 'node.exe' 6 "node $proj\frontend\node_modules\.bin\playwright test"
        # a background suite whose shell is gone, like the one that held 8137 and 8138
        & $row 30 999 'bash.exe' 27 '"C:\Program Files\Git\usr\bin\bash.exe" npm run e2e'
        & $row 31 30 'node.exe' 27 'node npm-cli.js run e2e'
        & $row 32 31 'python.exe' 28 "$proj\backend\.venv\Scripts\python.exe run.py"
        # an orphan that names nothing of this project
        & $row 40 998 'node.exe' 30 'node C:\elsewhere\server.js'
        # an orphan from before the target began
        & $row 50 997 'bash.exe' -30 "bash $proj\old.sh"
        # an editor opened on the project folder, whose launcher has exited
        & $row 60 996 'Code.exe' 31 "Code.exe $proj"
        # a pid reused by a younger process: the child's real parent is gone
        & $row 70 71 'cmd.exe' 32 "cmd /c $proj\build.cmd"
        & $row 71 10 'notepad.exe' 40 'notepad.exe'
    )
    $orphans = @(Get-OrphanedWork -Since $t0 -Dirs @($proj) -Processes $table)
    Test-Case 'the background tree whose shell is gone' (($orphans.ProcessId | Sort-Object) -join ',') '30,70'
    Test-Case 'is found by its root, not by every member' ($orphans.Count) 2

    if ($IsWindows) {
        # For real: a shell that starts something and exits at once, the way a background
        # command is started. The survivor names this test's directory, like a gate names
        # the project.
        $since = (Get-Date).AddSeconds(-1)
        $orphanPidFile = Join-Path $root 'orphan.pid'
        $launch = "`$o = Start-Process -FilePath '$pwsh' -ArgumentList '-NoProfile','-Command','Start-Sleep 120; ''$root'' | Out-Null' -PassThru -WindowStyle Hidden; Set-Content -LiteralPath '$orphanPidFile' -Value `$o.Id"
        $launcher = Start-Process -FilePath $pwsh -PassThru -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launch)))
        $launcher.WaitForExit(30000) | Out-Null
        $orphanPid = [int] (Get-Content -LiteralPath $orphanPidFile -TotalCount 1)
        Test-Case 'the launcher has exited, the orphan runs on' ([bool] (Get-Process -Id $orphanPid -ErrorAction SilentlyContinue)) $true

        $live = @(Get-OrphanedWork -Since $since -Dirs @($root))
        Test-Case 'it is found in the live process table' ($live.ProcessId -contains $orphanPid) $true
        foreach ($o in $live) { Stop-ProcessTree -Id ([int] $o.ProcessId) }
        Start-Sleep -Seconds 2
        Test-Case 'and stopped' ([bool] (Get-Process -Id $orphanPid -ErrorAction SilentlyContinue)) $false
    }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails) {
    Write-Host "$fails failed." -ForegroundColor Red
    exit 1
}
Write-Host 'all green.' -ForegroundColor Green
