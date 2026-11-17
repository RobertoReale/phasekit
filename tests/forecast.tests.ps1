<#
    The forecast: when a sequence ends once the usage limits are walked through. The
    shapes here are the ones real stream-json logs have: a session priced by its result,
    a rate-limit event naming its window, and a weekly reset that keeps a fixed cadence.

        pwsh -NoProfile -File tests/forecast.tests.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'lib' 'PhaseKit.ps1')

$fails = 0
function Test-Case($name, $got, $expected) {
    $ok = "$got" -eq "$expected"
    if (-not $ok) { $script:fails++ }
    $mark = if ($ok) { 'ok  ' } else { 'FAIL' }
    $colour = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  {0}  {1,-60} -> {2,-12} (expected {3})" -f $mark, $name, $got, $expected) -ForegroundColor $colour
}

$h = 3600.0
$t0 = 1800000000.0   # an arbitrary moment, in unix seconds

function New-Allowance($fiveSize, $fiveUsed, $fiveEnd, $weekSize, $weekUsed, $weekEnd) {
    [pscustomobject]@{
        five_hour = [pscustomobject]@{ size = $fiveSize; used = $fiveUsed; resetsAt = $fiveEnd; readings = 1 }
        seven_day = [pscustomobject]@{ size = $weekSize; used = $weekUsed; resetsAt = $weekEnd; readings = 1 }
    }
}

Write-Host 'walking work through the windows'

$free = New-Allowance $null 0 $null $null 0 $null
$w = Invoke-ForecastWalk -Work @([pscustomobject]@{ minutes = 60; usd = 10 }) -Allowance $free -Now $t0 -OverheadMinutes 0
Test-Case 'no known limit: the work alone' (($w.finish - $t0) / 60) 60
Test-Case 'no known limit: nothing waits' $w.waits 0

$w = Invoke-ForecastWalk -Work @([pscustomobject]@{ minutes = 60; usd = 10 }, [pscustomobject]@{ minutes = 60; usd = 10 }) -Allowance $free -Now $t0 -OverheadMinutes 8
Test-Case 'the gates run between targets' (($w.finish - $t0) / 60) 136

# A five-hour window of 10 USD, half used, closing in an hour: 5 USD of room. Two hours of
# work at 10 USD an hour runs 30 minutes and waits for the reset at +1h. The next window
# opens then and holds one hour of work, full at +2h, so the work waits again until that
# window closes at +6h and runs its last 30 minutes.
$a = New-Allowance 10 0.5 ($t0 + $h) $null 0 $null
$w = Invoke-ForecastWalk -Work @([pscustomobject]@{ minutes = 120; usd = 20 }) -Allowance $a -Now $t0 -OverheadMinutes 0
Test-Case 'a full five-hour window waits for its reset' (($w.finish - $t0) / 60) 390
Test-Case 'two waits' $w.waits 2

# The same work against a weekly window that is already full and resets in two days.
$a = New-Allowance $null 0 $null 100 1.0 ($t0 + 48 * $h)
$w = Invoke-ForecastWalk -Work @([pscustomobject]@{ minutes = 60; usd = 10 }) -Allowance $a -Now $t0 -OverheadMinutes 0
Test-Case 'a full week waits for the weekly reset' (($w.finish - $t0) / $h) 49

# A weekly window never moves its reset: past one reset, the next is a week later.
$a = New-Allowance $null 0 $null 10 0 ($t0 + $h)
$w = Invoke-ForecastWalk -Work @([pscustomobject]@{ minutes = 240; usd = 30 }) -Allowance $a -Now $t0 -OverheadMinutes 0
# 7.5 USD an hour against 10 USD a week. 60 minutes run before the reset at +1h. The
# fresh week holds 80 minutes, full at +2h20m. The next reset is a week after the first,
# at +169h, and holds 80 more, full at +170h20m. The last 20 minutes wait for +337h.
Test-Case 'the weekly cadence is fixed' ([Math]::Round(($w.finish - $t0) / 60)) (337 * 60 + 20)

# An unpriced target still takes its time.
$a = New-Allowance 10 0.99 ($t0 + $h) 100 0.99 ($t0 + 24 * $h)
$w = Invoke-ForecastWalk -Work @([pscustomobject]@{ minutes = 30; usd = 0 }) -Allowance $a -Now $t0 -OverheadMinutes 0
Test-Case 'work that costs nothing never waits' (($w.finish - $t0) / 60) 30

Write-Host ''
Write-Host 'measuring the windows'

# Spend of 1 USD every 10 minutes for ten hours, and two readings.
$reqs = @(for ($i = 0; $i -lt 60; $i++) { [pscustomobject]@{ t = $t0 + $i * 600; usd = 1.0 } })
$limits = @(
    # A five-hour window that opened at t0, warned at 90% after 18 USD: it holds 20.
    [pscustomobject]@{ t = $t0 + 17 * 600; type = 'five_hour'; status = 'allowed_warning'; resetsAt = $t0 + 5 * $h; util = 0.9 },
    # A week that ends three days after t0 and was rejected after the 60 USD: it holds 60.
    [pscustomobject]@{ t = $t0 + 59 * 600; type = 'seven_day'; status = 'rejected'; resetsAt = $t0 + 72 * $h; util = $null }
)
$hist = New-SpendIndex -Requests $reqs -Limits $limits
Test-Case 'spend between two moments' (Get-SpendBetween -History $hist -From $t0 -To ($t0 + 600)) 2
Test-Case 'spend before the first request' (Get-SpendBefore -History $hist -At ($t0 - 1)) 0
Test-Case 'first request after a moment' ((Get-FirstRequestAfter -History $hist -After ($t0 + 1)) - $t0) 600

$model = Get-AllowanceModel -History $hist -Now ($t0 + 59 * 600 + 1)
Test-Case 'five-hour size from a warning' ([Math]::Round($model.five_hour.size, 1)) 20
Test-Case 'weekly size from a rejection' ([Math]::Round($model.seven_day.size, 1)) 60
Test-Case 'the week stays full until its reset' ([Math]::Round($model.seven_day.used, 2)) 1
Test-Case 'the weekly reset is the one named' ($model.seven_day.resetsAt - $t0) (72 * $h)
# The named five-hour window closed at +5h; work went on, so the next one opened with
# the first request after it and is still open.
Test-Case 'a closed five-hour window is followed by the next' ($model.five_hour.resetsAt - $t0) (5 * $h + 600 + 5 * $h)

$later = Get-AllowanceModel -History $hist -Now ($t0 + 80 * $h)
Test-Case 'a passed weekly reset moves on by a week' ($later.seven_day.resetsAt - $t0) ((72 + 168) * $h)
Test-Case 'a fresh week is empty' $later.seven_day.used 0

Write-Host ''
Write-Host 'reading a log'

$dir = Join-Path ([IO.Path]::GetTempPath()) ('phasekit-forecast-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    $log = Join-Path $dir 'phase-T.1-20261101-100000.log'
    @(
        '{"type":"system","subtype":"init","session_id":"s"}'
        '{"type":"assistant","message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}},"request_id":"r1","timestamp":"2026-11-01T10:00:00.000Z"}'
        '{"type":"assistant","message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":9}},"request_id":"r1","timestamp":"2026-11-01T10:00:01.000Z"}'
        '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1793530800,"rateLimitType":"seven_day","utilization":0.8}}'
        '{"type":"user","timestamp":"2026-11-01T10:05:00.000Z"}'
        '{"type":"assistant","message":{"usage":{"input_tokens":30,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}},"request_id":"r2","timestamp":"2026-11-01T10:06:00.000Z"}'
        '{"type":"result","subtype":"success","total_cost_usd":4.0}'
        '{"type":"system","subtype":"init","session_id":"s"}'
        '{"type":"assistant","message":{"usage":{"input_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}},"request_id":"r3","timestamp":"2026-11-01T14:00:00.000Z"}'
    ) | Set-Content -LiteralPath $log -Encoding utf8

    $u = Read-LogUsage -LogPath $log
    Test-Case 'a repeated request counts once' @($u.requests).Count 3
    Test-Case 'the finished session is priced by its result' $u.usd 4
    Test-Case 'its cost follows the input weight' (@($u.requests)[1].usd) 3
    Test-Case 'the open session is left for the caller' $u.openWeight 20
    Test-Case 'a night of waiting is not activity' ([Math]::Round($u.active, 2)) 6
    Test-Case 'the rate-limit event is read' @($u.limits)[0].util 0.8

    $hist = Get-UsageHistory -LogDir $dir
    Test-Case 'the open session is priced at the measured rate' ([Math]::Round($hist.targets['T.1'].usd, 2)) 6
    Test-Case 'the cache is written' (Test-Path (Join-Path $dir 'usage-cache.json')) 'True'
    $again = Get-UsageHistory -LogDir $dir
    Test-Case 'and read back the same' ([Math]::Round($again.targets['T.1'].usd, 2)) 6
}
finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host 'when the measured week is full but the work can go elsewhere'

# The week of 'measuring the windows': rejected after 60 USD, back at +72h. One target
# done (an hour, 10 USD), one to go. 2026-11-17: the pool read 100%, the forecast waited
# for the weekly reset, and another account with its whole week was doing the work.
$targets = [ordered]@{ 'T.1' = [pscustomobject]@{ active = 60; usd = 10; lastT = $t0 + 59 * 600 } }
$full = New-SpendIndex -Requests $reqs -Limits $limits -Targets $targets
$frame = [pscustomobject]@{ rows = @(
    [pscustomobject]@{ target = 'T.1'; state = 'done'; model = 'opus' },
    [pscustomobject]@{ target = 'T.2'; state = 'queued'; model = 'opus' }
) }
$at = ConvertFrom-UnixSeconds ($t0 + 59 * 600 + 1)
$hoursFrom = { param($fc) [Math]::Round((ConvertTo-UnixSeconds $fc.typical.finish) - ($t0 + 59 * 600 + 1)) / 60 }
$fc = Get-CompletionForecast -Frame $frame -History $full -At $at
Test-Case 'nowhere else: it waits for the weekly reset' ((ConvertTo-UnixSeconds $fc.typical.finish) -ge $t0 + 72 * $h) 'True'
$fc = Get-CompletionForecast -Frame $frame -History $full -At $at -Elsewhere fallback
Test-Case 'a fallback model: the work alone, gates included' (& $hoursFrom $fc) 68
Test-Case 'and the dashboard says why' ((Format-ForecastLines -Forecast $fc)[1].text -match 'limitFallback takes over') 'True'
$fc = Get-CompletionForecast -Frame $frame -History $full -At $at -Elsewhere account
Test-Case 'a free account: starts on an empty allowance' (& $hoursFrom $fc) 68
Test-Case 'the measured week is still shown as it is' ([Math]::Round($fc.allowance.seven_day.used, 2)) 1

# Between targets: gates, review, merge. Four targets an hour each, 30 minutes apart,
# except one five-hour gap that was a wait and says nothing about the overhead.
$spaced = [ordered]@{}
$starts = @(0, 90, 180, 540, 630)
for ($i = 0; $i -lt $starts.Count; $i++) {
    $first = $t0 - 1000 * 60 + $starts[$i] * 60
    $spaced["S.$i"] = [pscustomobject]@{ active = 60; usd = 10; firstT = $first; lastT = $first + 3600 }
}
$rows = @($spaced.Keys | ForEach-Object { [pscustomobject]@{ target = $_; state = 'done'; model = 'opus' } }) +
        @([pscustomobject]@{ target = 'S.next'; state = 'queued'; model = 'opus' })
$fc = Get-CompletionForecast -Frame ([pscustomobject]@{ rows = $rows }) -History (New-SpendIndex -Requests @() -Limits @() -Targets $spaced) -At (ConvertFrom-UnixSeconds $t0) -Elsewhere fallback
Test-Case 'the time between targets is measured, waits left out' $fc.overheadMinutes 30
Test-Case 'and the walk adds it' (((ConvertTo-UnixSeconds $fc.typical.finish) - $t0) / 60) 90

Write-Host ''
Write-Host 'the summary'

$fc = [pscustomobject]@{
    samples   = 3
    allowance = New-Allowance 20 0.5 ($t0 + $h) 60 0.25 ($t0 + 72 * $h)
    quick     = [pscustomobject]@{ finish = (ConvertFrom-UnixSeconds ($t0 + 10 * $h)); waits = 0; workMinutes = 300 }
    typical   = [pscustomobject]@{ finish = (ConvertFrom-UnixSeconds ($t0 + 20 * $h)); waits = 1; workMinutes = 600 }
    slow      = [pscustomobject]@{ finish = (ConvertFrom-UnixSeconds ($t0 + 40 * $h)); waits = 2; workMinutes = 900 }
}
$s = ConvertTo-ForecastSummary -Forecast $fc
Test-Case 'the summary carries the typical end' ($null -ne $s.typical) 'True'
Test-Case 'and the weekly use' $s.sevenDay.used 0.25
Test-Case 'two dashboard lines' @(Format-ForecastLines -Forecast $fc).Count 2
Test-Case 'no forecast, no lines' @(Format-ForecastLines -Forecast $null).Count 0
Test-Case 'no forecast, an unavailable summary' (ConvertTo-ForecastSummary -Forecast $null).available 'False'

Write-Host ''
if ($fails -gt 0) { Write-Host "$fails failing" -ForegroundColor Red; exit 1 }
Write-Host 'all green.' -ForegroundColor Green
exit 0
