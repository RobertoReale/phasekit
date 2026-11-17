<#
    What the person watching sees about usage: tokens by kind per target, the API-price
    figure counted once per process, Claude's own allowance readings per account, and the
    line printed after every turn.

        pwsh -NoProfile -File tests/usage.tests.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'lib' 'PhaseKit.ps1')

$fails = 0
function Test-Case($name, $got, $expected) {
    $ok = "$got" -eq "$expected"
    if (-not $ok) { $script:fails++ }
    $mark = if ($ok) { 'ok  ' } else { 'FAIL' }
    $colour = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  {0}  {1,-60} -> {2} (expected {3})" -f $mark, $name, $got, $expected) -ForegroundColor $colour
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('phasekit-usage-test-' + [guid]::NewGuid().ToString('N'))
$logs = Join-Path $root 'logs'
New-Item -ItemType Directory -Path $logs -Force | Out-Null

function Req([string] $id, [int] $fresh, [int] $read, [int] $write, [int] $out) {
    '{"type":"assistant","request_id":"' + $id + '","message":{"usage":{"input_tokens":' + $fresh + ',"cache_creation_input_tokens":' + $write +
    ',"cache_read_input_tokens":' + $read + ',"output_tokens":' + $out + '}}}'
}
function Res([double] $usd, [int] $fresh, [int] $read, [int] $write, [int] $out) {
    '{"type":"result","subtype":"success","num_turns":1,"total_cost_usd":' + $usd.ToString([cultureinfo]::InvariantCulture) +
    ',"usage":{"input_tokens":' + $fresh + ',"cache_creation_input_tokens":' + $write + ',"cache_read_input_tokens":' + $read + ',"output_tokens":' + $out + '}}'
}

try {
    Write-Host 'one log, two processes, the first woken twice'
    # Process 1: a turn ($1.00), then a turn after a background command ($1.20 running
    # total). A note, then process 2 ($0.50). Then process 3 still running, no result yet.
    $log = Join-Path $logs 'phase-A.1-20261117-100000.log'
    @(
        '[phasekit] account main'
        '{"type":"system","subtype":"init","session_id":"s"}'
        (Req 'r1' 10 1000 100 1)
        (Res 1.00 10 1000 100 700)
        '{"type":"system","subtype":"init","session_id":"s"}'
        (Req 'r2' 5 2000 50 1)
        (Res 1.20 5 2000 50 300)
        '[phasekit] account b'
        '{"type":"system","subtype":"init","session_id":"s"}'
        (Req 'r3' 1 500 0 1)
        (Res 0.50 1 500 0 100)
        '[phasekit] Resuming the same conversation after the stall (attempt 1 of 2).'
        (Req 'r4' 7 4000 10 9)
    ) | Set-Content -LiteralPath $log
    $s = Get-LogSpend -LogPath $log
    Test-Case 'a running total counts once: 1.20 + 0.50' ([math]::Round($s.usd, 2)) 1.7
    Test-Case 'every request is counted' $s.requests 4
    Test-Case 'output from the results, plus the one still running' $s.output 1109
    Test-Case 'cache reads the same way' $s.read 7500
    Test-Case 'the context now is the last request''s' $s.last 4017

    Write-Host 'a target, every attempt and its reviews'
    @(
        '[phasekit] account main'
        (Req 'v1' 100 3000 0 1)
        (Res 0.30 100 3000 0 200)
    ) | Set-Content -LiteralPath (Join-Path $logs 'review-A.1-20261117-110000.log')
    @((Req 'x1' 1 1 1 1); (Res 9.99 1 1 1 1)) | Set-Content -LiteralPath (Join-Path $logs 'phase-A.10-20261117-110000.log')
    $t = Get-TargetSpend -LogDir $logs -Target 'A.1'
    Test-Case 'attempts and reviews add up' ([math]::Round($t.usd, 2)) 2
    Test-Case 'the reviews are also told apart' ([math]::Round($t.reviewUsd, 2)) 0.3
    Test-Case 'A.10 is not A.1' $t.requests 5
    Test-Case 'the context is the work''s, not the reviewer''s' $t.context 4017
    $line = Format-SpendLine $t
    Test-Case 'one readable line' $line '5 requests, 123 new in, 11k cache read, 160 cache write, 1.3k out, ~$2.00 at API prices'

    Write-Host 'after every turn'
    $script:StreamLogPath = $log
    $printed = (Write-StreamLine -Line (Res 1.20 0 0 0 0) 6>&1 | Out-String)
    Test-Case 'the turn''s end says what the target used so far' ($printed -match 'A\.1 so far: 5 requests') 'True'
    $script:StreamLogPath = Join-Path $logs 'not-a-phase.log'
    $printed = (Write-StreamLine -Line (Res 1.20 0 0 0 0) 6>&1 | Out-String)
    Test-Case 'a log that is no target''s says nothing more' ($printed -match 'so far') 'False'

    Write-Host 'the forecast counts a running total once too'
    $u = Read-LogUsage -LogPath $log
    Test-Case 'the forecast''s total' ([math]::Round($u.usd, 2)) 1.7

    Write-Host 'Claude''s own readings, per account'
    $now = Get-Date
    $soon = [int64] (ConvertTo-UnixSeconds $now.AddHours(2).ToUniversalTime())
    $week = [int64] (ConvertTo-UnixSeconds $now.AddDays(3).ToUniversalTime())
    $gone = [int64] (ConvertTo-UnixSeconds $now.AddHours(-1).ToUniversalTime())
    $rl = { param($type, $status, $resets, $util)
        $u = if ($null -ne $util) { ',"utilization":' + $util } else { '' }
        '{"type":"rate_limit_event","rate_limit_info":{"status":"' + $status + '","resetsAt":' + $resets + ',"rateLimitType":"' + $type + '"' + $u + '}}' }
    $readLogs = Join-Path $root 'readings'
    New-Item -ItemType Directory -Path $readLogs -Force | Out-Null
    @(
        '[phasekit] account b'
        (& $rl 'seven_day' 'allowed_warning' $week 0.91)
        (& $rl 'five_hour' 'allowed_warning' $soon 0.94)
        (& $rl 'five_hour' 'rejected' $soon $null)
        '[phasekit] account main'
        (& $rl 'five_hour' 'allowed_warning' $gone 0.97)
    ) | Set-Content -LiteralPath (Join-Path $readLogs 'phase-B.1-20261117-090000.log')
    # Written before the account line existed: whose it was is unknown, so it is left out.
    @((& $rl 'seven_day' 'allowed_warning' $week 0.99)) | Set-Content -LiteralPath (Join-Path $readLogs 'phase-B.0-20261116-090000.log')

    $r = Get-AccountReadings -LogDir $readLogs -Now $now
    Test-Case 'a refusal is 100%' $r['b']['five_hour'].pct 1
    Test-Case 'a warning is its share' $r['b']['seven_day'].pct 0.91
    Test-Case 'a window that has reset is dropped' ($r.ContainsKey('main') -and $r['main'].ContainsKey('five_hour')) 'False'
    Test-Case 'an unmarked log is nobody''s' $r.Count 1

    $accts = @([pscustomobject]@{ name = 'main'; dir = 'x' }, [pscustomobject]@{ name = 'b'; dir = 'y' })
    $lines = @(Format-AccountLines -Readings $r -Accounts $accts -Active 'b' -Limits @{} -Now $now)
    Test-Case 'one line per account' $lines.Count 2
    Test-Case 'the spent one shows its numbers' ($lines[1].text -match '\* b\s+5h 100% \(resets .+\)\s+week 91%') 'True'
    Test-Case 'one with no warning says so, not 0%' ($lines[0].text -match 'main\s+no warning from Claude') 'True'
    $lines = @(Format-AccountLines -Readings @{} -Accounts $accts -Active 'main' -Limits @{ main = $now.AddHours(3) } -Now $now)
    Test-Case 'an account set aside says until when' ($lines[0].text -match 'set aside until') 'True'
}
finally {
    $script:StreamLogPath = $null
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails) { Write-Host "$fails failed." -ForegroundColor Red; exit 1 }
Write-Host 'all green.' -ForegroundColor Green
