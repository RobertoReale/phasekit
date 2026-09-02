<#
    What the dashboard claims about a run: how long each target took, and how much of it
    is left. Every shape here is one a real log directory has produced.

        pwsh -NoProfile -File tests/pace.tests.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'lib' 'PhaseKit.ps1')

$fails = 0
function Test-Case($name, $got, $expected) {
    $ok = "$got" -eq "$expected"
    if (-not $ok) { $script:fails++ }
    $mark = if ($ok) { 'ok  ' } else { 'FAIL' }
    $colour = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  {0}  {1,-52} -> {2,-12} (expected {3})" -f $mark, $name, $got, $expected) -ForegroundColor $colour
}

Write-Host 'reading a duration'

Test-Case 'under a minute is not rounded down to nothing' (Format-Duration 0.4) '<1m'
Test-Case 'minutes' (Format-Duration 25.4) '25m'
Test-Case 'an exact hour drops the minutes' (Format-Duration 120) '2h'
Test-Case 'hours and minutes' (Format-Duration 145) '2h 25m'
Test-Case 'past a day, quoted in days' (Format-Duration 3351) '2d 7h'
Test-Case 'nothing measured yet' (Format-Duration $null) '--'

Write-Host ''
Write-Host 'the typical target'

# The real distribution this was built against: fourteen finished targets, two of which
# spent days waiting for an allowance to reset rather than working.
$real = @(6, 12, 18, 19, 21, 23, 25, 26, 40, 106, 233, 279, 416, 3351)

Test-Case 'the median ignores the weekend-long outlier' (Get-Percentile -Values $real -P 0.5) 25.5
Test-Case 'the quick quarter' (Get-Percentile -Values $real -P 0.25) 19.5
Test-Case 'one sample is its own median' (Get-Percentile -Values @(42) -P 0.5) 42
Test-Case 'nothing measured' ($null -eq (Get-Percentile -Values @() -P 0.5)) $true

# The mean is what this deliberately is not: one stalled target moves it by a factor of
# nine, and an estimate built on it would have said months.
$mean = ($real | Measure-Object -Average).Average
Test-Case 'the mean would have been this far out' ([int] $mean) 327

Write-Host ''
Write-Host 'what the logs say about each target'

$dir = Join-Path ([System.IO.Path]::GetTempPath()) ("phasekit-pace-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    function New-Log($name, $endsAfterMinutes) {
        $path = Join-Path $dir $name
        Set-Content -LiteralPath $path -Value 'x'
        if ($name -match '-(?<stamp>\d{8}-\d{6})\.log$') {
            $start = [datetime]::ParseExact($Matches['stamp'], 'yyyyMMdd-HHmmss', $null)
            (Get-Item -LiteralPath $path).LastWriteTime = $start.AddMinutes($endsAfterMinutes)
        }
    }

    # G.5 as it actually happened: seven attempts across three days, two of them the run
    # sitting out a usage limit, the last one a reply that finished it.
    New-Log 'phase-G.5-20260831-014407.log' 241
    New-Log 'phase-G.5-20260831-054453.log' 241
    New-Log 'phase-G.5-20260902-121804.log' 8
    # A.2's attempts are interleaved with 0.4's — the reason a target costs the sum of its
    # attempts and not the span from its first to its last.
    New-Log 'phase-A.2-20260830-032546.log' 2
    New-Log 'phase-A.2-20260830-103153.log' 19
    New-Log 'phase-0.4-20260830-094910.log' 21
    # Neither of these is a phase log, and neither may be counted as one.
    Set-Content -LiteralPath (Join-Path $dir 'auto-stopped.txt') -Value 'Why: something'
    Set-Content -LiteralPath (Join-Path $dir 'phase-G.5.session') -Value 'abc'

    $stats = Get-TargetLogStats -LogDir $dir

    Test-Case 'only the phase logs are counted' $stats.Count 3
    Test-Case 'every attempt at a target is one attempt' $stats['G.5'].attempts 3
    Test-Case 'a target costs the sum of its attempts' ([int] $stats['G.5'].minutes) 490
    Test-Case 'interleaving does not bill A.2 for 0.4' ([int] $stats['A.2'].minutes) 21
    Test-Case 'the span from first to last would have said' `
        ([int] ($stats['A.2'].last - $stats['A.2'].first).TotalMinutes) 445
    Test-Case 'the newest attempt is the one still running' `
        ($stats['A.2'].latest.ToString('HH:mm')) '10:31'

    Test-Case 'an empty log directory is not an error' (Get-TargetLogStats -LogDir (Join-Path $dir 'nope')).Count 0
}
finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host 'how much longer'

$pace = Get-RunPace -TargetMinutes $real -ElapsedMinutes 5240 -Finished 15 -Remaining 38

Test-Case 'the working estimate is the median, projected' ([int] $pace.workingLeft) 969
Test-Case 'the observed pace counts the waiting too' ([int] $pace.observedMinutes) 349
Test-Case 'and projects to something much longer' ([int] $pace.observedLeft) 13275
Test-Case 'a run with nothing finished promises nothing' `
    ($null -eq (Get-RunPace -TargetMinutes @() -ElapsedMinutes $null -Finished 0 -Remaining 12).workingLeft) $true

Write-Host ''
Write-Host 'the plan names its own targets'

$plan = @(
    '- [x] G.5 "nothing found" is not "ok"',
    '- [ ] G.2 the user sees the zones they picked *(runs after Phase D)*',
    'not a ledger line at all',
    '  - [ ] H.1 the result window has to be stable'
)
$labels = Get-LedgerLabels -PlanLines $plan

Test-Case 'a ticked box still names its target' $labels['G.5'] '"nothing found" is not "ok"'
Test-Case 'an indented box counts' $labels['H.1'] 'the result window has to be stable'
Test-Case 'prose is not a ledger line' $labels.ContainsKey('not') $false

Write-Host ''
if ($fails) {
    Write-Host "$fails failed." -ForegroundColor Red
    exit 1
}
Write-Host 'all green.' -ForegroundColor Green
