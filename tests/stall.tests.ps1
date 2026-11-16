<#
    The stall guard: an agent that stops writing is stopped and resumed, one that keeps
    talking is left alone, and Antigravity idling on background tasks is caught sooner.
    The fake agent here is a real child process, because that is what the guard stops.

        pwsh -NoProfile -File tests/stall.tests.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'lib' 'PhaseKit.ps1')

$fails = 0
function Test-Case($name, $got, $expected) {
    $ok = "$got" -eq "$expected"
    if (-not $ok) { $script:fails++ }
    $mark = if ($ok) { 'ok  ' } else { 'FAIL' }
    $colour = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  {0}  {1,-58} -> {2,-8} (expected {3})" -f $mark, $name, $got, $expected) -ForegroundColor $colour
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('phasekit-stall-test-' + [guid]::NewGuid().ToString('N'))
$bin = Join-Path $root 'bin'
New-Item -ItemType Directory -Path $bin -Force | Out-Null
$savedPath = $env:PATH
$savedMode = $env:PK_STALL_MODE

# A claude that is a process of its own. PK_STALL_MODE says what it does:
#   hang      the init line, then nothing for five minutes
#   talk      a line a second for six seconds, then a clean end
#   idle      Antigravity's idle line, then nothing
#   once      hang on the first call, end cleanly on the next (counted in calls.txt)
@'
$calls = Join-Path $PSScriptRoot 'calls.txt'
Add-Content -LiteralPath $calls -Value 'call'
$n = @(Get-Content -LiteralPath $calls).Count
'{"type":"system","subtype":"init","session_id":"s1","cwd":"."}'
switch ($env:PK_STALL_MODE) {
    'talk' { 1..6 | ForEach-Object { Start-Sleep -Seconds 1; '{"type":"system","subtype":"status","status":"working"}' } }
    'idle' { 'root agent idle; waiting for 2 background task(s) to finish'; Start-Sleep -Seconds 300 }
    'once' { if ($n -eq 1) { Start-Sleep -Seconds 300 } }
    default { Start-Sleep -Seconds 300 }
}
'{"type":"result","subtype":"success","result":"done","session_id":"s1"}'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $bin 'agent.ps1')
if ($IsWindows) {
    Set-Content -LiteralPath (Join-Path $bin 'claude.cmd') -Value "@pwsh -NoProfile -File `"%~dp0agent.ps1`" %*"
} else {
    $sh = Join-Path $bin 'claude'
    Set-Content -LiteralPath $sh -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"`$(dirname `"`$0`")/agent.ps1`" `"`$@`"`n" -NoNewline
    & chmod +x $sh
}
$env:PATH = $bin + [IO.Path]::PathSeparator + $env:PATH

function Invoke-Fake([string] $Mode, [double] $Minutes) {
    $env:PK_STALL_MODE = $Mode
    Remove-Item -LiteralPath (Join-Path $bin 'calls.txt') -ErrorAction SilentlyContinue
    $log = Join-Path $root "$Mode-$([guid]::NewGuid().ToString('N').Substring(0, 6)).log"
    $script:StallMinutes = $Minutes
    $started = Get-Date
    $code = Invoke-Agent -ClaudeArgs @('-p', 'go', '--model', 'sonnet') -LogPath $log -SessionFile (Join-Path $root 'session') 6>$null
    return [pscustomobject]@{
        code = $code; seconds = ((Get-Date) - $started).TotalSeconds; stalled = $script:LastAgentStalled
        log = $(if (Test-Path $log) { Get-Content -LiteralPath $log -Raw } else { '' })
    }
}

try {
    Write-Host 'an agent that stops writing'
    $r = Invoke-Fake 'hang' 0.05
    Test-Case 'is stopped, not waited for' ($r.seconds -lt 60) 'True'
    Test-Case 'and the run says it was stuck' $r.stalled 'True'
    Test-Case 'a stopped agent is not a success' ($r.code -ne 0) 'True'
    Test-Case 'the log says why' ($r.log -match 'the agent was stuck') 'True'

    Write-Host 'an agent that keeps talking'
    $r = Invoke-Fake 'talk' 0.05
    Test-Case 'is left alone' "$($r.code)|$($r.stalled)" '0|False'

    Write-Host 'Antigravity idling on background tasks'
    $r = Invoke-Fake 'idle' 0.25
    Test-Case 'is caught in a fifth of the time' ($r.stalled -and $r.seconds -lt 12) 'True'

    Write-Host 'the guard off'
    $r = Invoke-Fake 'talk' 0
    Test-Case 'stallMinutes 0 runs the agent as before' "$($r.code)|$($r.stalled)" '0|False'

    Write-Host 'a stall, then a resume in the same conversation'
    $env:PK_STALL_MODE = 'once'
    Remove-Item -LiteralPath (Join-Path $bin 'calls.txt') -ErrorAction SilentlyContinue
    $log = Join-Path $root 'once.log'
    $script:SessionId = 's1'
    $script:ContinuePrompt = 'carry on'
    $cfg = [pscustomobject]@{ maxRetries = 2; maxContextRestarts = 2; waitMinutes = 1; stallMinutes = 0.05; agyCredits = $false
                              switchAccounts = $false; limitFallback = @() }
    $code = Invoke-AgentWithLimitRetry -Config $cfg -Phase 'X' -FirstArgs @('-p', 'go', '--model', 'sonnet') `
        -LogPath $log -SessionFile (Join-Path $root 'session') -Common @('--model', 'sonnet') 6>$null
    Test-Case 'the resumed run ends cleanly' $code 0
    Test-Case 'two calls: the stuck one and the resume' (@(Get-Content -LiteralPath (Join-Path $bin 'calls.txt')).Count) 2
    Test-Case 'the log says it resumed' ((Get-Content -LiteralPath $log -Raw) -match 'Resuming the same conversation after the stall') 'True'

    Write-Host 'settings'
    $dir = Join-Path $root 'cfg'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'phasekit.json') -Value '{ "gates": [] }'
    Test-Case 'on by default, at 45 minutes' (Get-PhaseKitConfig -Path (Join-Path $dir 'phasekit.json')).stallMinutes 45
    Set-Content -LiteralPath (Join-Path $dir 'phasekit.json') -Value '{ "stallMinutes": 0, "gates": [] }'
    Test-Case '0 turns it off' (Get-PhaseKitConfig -Path (Join-Path $dir 'phasekit.json')).stallMinutes 0
    Set-Content -LiteralPath (Join-Path $dir 'phasekit.json') -Value '{ "stallMinutes": "soon", "gates": [] }'
    $threw = $false
    try { $null = Get-PhaseKitConfig -Path (Join-Path $dir 'phasekit.json') } catch { $threw = $_.Exception.Message -match 'stallMinutes' }
    Test-Case 'a value that is not minutes is refused' $threw 'True'
}
finally {
    $env:PATH = $savedPath
    $env:PK_STALL_MODE = $savedMode
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails) { Write-Host "$fails failed." -ForegroundColor Red; exit 1 }
Write-Host 'all green.' -ForegroundColor Green
