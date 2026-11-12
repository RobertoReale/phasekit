<#
    The agent's log is written line by line while other things read it: the forecast, the
    report, an editor. On Windows a reader that does not share writing makes the next append
    throw, and the runner once read that throw as a failed start and stopped the sequence
    with the agent still working. Both sides are covered here.

        pwsh -NoProfile -File tests/logshare.tests.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'lib' 'PhaseKit.ps1')

$fails = 0
function Test-Case($name, $got, $expected) {
    $ok = "$got" -eq "$expected"
    if (-not $ok) { $script:fails++ }
    $mark = if ($ok) { 'ok  ' } else { 'FAIL' }
    $colour = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  {0}  {1,-62} -> {2,-8} (expected {3})" -f $mark, $name, $got, $expected) -ForegroundColor $colour
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('phasekit-logshare-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$log = Join-Path $root 'phase-A.1-20261112-100000.log'

try {
    Set-Content -LiteralPath $log -Value '{"type":"system","subtype":"init","session_id":"s"}' -Encoding utf8

    Write-Host 'reading the log while it is being written'

    # What Add-Content holds while it appends.
    $writer = [System.IO.FileStream]::new($log, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write,
                                          [System.IO.FileShare]::ReadWrite)
    $read = $null
    try { $read = Read-LogUsage -LogPath $log } catch { $read = $null }
    finally { $writer.Dispose() }
    Test-Case 'the usage reader opens a log that is open for writing' ($null -ne $read) 'True'

    $reader = [System.IO.FileStream]::new($log, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                                          [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    $threw = $false
    try { Add-LogLine -LogPath $log -Line '{"type":"x","n":1}' } catch { $threw = $true }
    finally { $reader.Dispose() }
    Test-Case 'and an append goes through while the reader is open' (-not $threw -and (Get-Content -LiteralPath $log -Raw) -match '"n":1') 'True'

    Write-Host ''
    Write-Host 'a reader that does not share writing'

    $blocker = [System.IO.FileStream]::new($log, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                                           [System.IO.FileShare]::Read)
    $job = Start-ThreadJob -ScriptBlock { param($s) Start-Sleep -Milliseconds 800; $s.Dispose() } -ArgumentList $blocker
    $threw = $false
    try { Add-LogLine -LogPath $log -Line '{"type":"x","n":2}' } catch { $threw = $true }
    $job | Wait-Job | Remove-Job
    Test-Case 'a short hold is waited out, not thrown' $threw 'False'
    Test-Case 'and the line lands' ((Get-Content -LiteralPath $log -Raw) -match '"n":2') 'True'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails -gt 0) { Write-Host "$fails failing" -ForegroundColor Red; exit 1 }
Write-Host 'all green.' -ForegroundColor Green
exit 0
