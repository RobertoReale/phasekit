<#
    Two things a long unattended run depends on and neither of which shows up until it is
    too late: reading the plan back as a table of contents, and knowing whether a runner
    is still there.

        pwsh -NoProfile -File tests/resilience.tests.ps1
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

# ---------------------------------------------------------------------------
# The plan, read as a table of contents
# ---------------------------------------------------------------------------

Write-Host 'reading a plan back'

# Shaped like a real one, including the two things that broke the first parser: a phase
# numbered "9A", and a heading that names two phases at once.
$plan = @(
    '# PLAN.md - Cycle 3'
    ''
    '## 7. PHASE D - the information architecture'
    ''
    '### D.1 - The shell'
    ''
    '**Files:** `src/App.tsx`, `src/routes.tsx`,'
    '`src/components/Nav.tsx`.'
    ''
    'One frame around every screen. Today each page draws its own header, which is why'
    'the nav jumps by two pixels between Listings and Insights.'
    ''
    '**Vincolo - no new dependency.**'
    ''
    '## 8. PHASE E and F - finish'
    ''
    '### E.1 - States'
    ''
    'Empty, loading, error and offline, for every list in the product.'
    ''
    '## 9A. PHASE H - the scan is correct, and it is fast'
    ''
    '### H.1 - The result window has to be stable'
    ''
    'A scan reads page 2 of a list that reordered itself between page 1 and page 2.'
    ''
    '## 10. Ledger'
    ''
    '- [x] D.1 the shell'
    '- [ ] E.1 states'
    '- [ ] H.1 the result window has to be stable'
)

$outline = Get-PlanOutline -PlanLines $plan

Test-Case 'a phase numbered 9A is still a phase' $outline.phases['H'] 'the scan is correct, and it is fast'
Test-Case 'one heading, two phases: E' $outline.phases['E'] 'finish'
Test-Case 'one heading, two phases: F' $outline.phases['F'] 'finish'
Test-Case 'a target keeps its own title' $outline.targets['D.1'].title 'The shell'

# The bug this was written for: the file list is a paragraph, and skipping it line by line
# left its last line standing as the summary of the task.
Test-Case 'the summary is prose, not the tail of a file list' `
    $outline.targets['D.1'].summary `
    'One frame around every screen. Today each page draws its own header, which is why the nav jumps by two pixels between Listings and Insights.'

Test-Case 'a section body stops at the next heading' `
    (@($outline.targets['E.1'].body | Where-Object { $_ -match 'PHASE' }).Count) 0

$labels = Get-LedgerLabels -PlanLines $plan
Test-Case 'the ledger still yields its own short labels' $labels['D.1'] 'the shell'

# ---------------------------------------------------------------------------
# What a target is run with
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'what a target is run with'

$seqCfg = [pscustomobject]@{ autoSequence = @(
    '4.2'
    [pscustomobject]@{ target = '4.3'; model = 'sonnet' }
    [pscustomobject]@{ target = '4.4'; effort = 'medium' }
) }
$seq = Get-AutoSequence -Config $seqCfg

Test-Case 'a bare string names neither' "$($seq[0].model)/$($seq[0].effort)" '/'
Test-Case 'an entry may name the model alone' "$($seq[1].model)/$($seq[1].effort)" 'sonnet/'
Test-Case 'an entry may name the effort alone' "$($seq[2].model)/$($seq[2].effort)" '/medium'

# Naming a target on the command line says WHICH to run, not that everything the config
# knows about it should be forgotten. Effort had to join model, the note and
# allowNoCommits here, or `phasekit auto -Targets C.4` would silently run at the default.
$picked = Get-AutoSequence -Config $seqCfg -Targets '4.4'
Test-Case '-Targets keeps the entry it was given' $picked[0].effort 'medium'

# ---------------------------------------------------------------------------
# What a session is handed, and what it costs
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'the size of a conversation'

$tmpPlan = Join-Path ([System.IO.Path]::GetTempPath()) ("phasekit-plan-" + [guid]::NewGuid().ToString('N') + '.md')
Set-Content -LiteralPath $tmpPlan -Value $plan
$planCfg = [pscustomobject]@{ plan = $tmpPlan }

try {
    # Quoting the section is the whole point: a real plan is over a hundred kilobytes, and
    # a prompt that says "read PLAN.md" pays for it on every request the session makes
    # afterwards, not once.
    $section = Get-PlanSectionText -Config $planCfg -Phase 'D.1'
    Test-Case 'the section carries its own heading' ($section -split "`n")[0] '### D.1 - The shell'
    Test-Case 'the section carries the task body' `
        ([bool] ($section -match 'the nav jumps by two pixels')) $true
    Test-Case 'the section stops at the next task' ([bool] ($section -match 'PHASE E')) $false
    Test-Case 'a target the plan does not have yields nothing' `
        (Get-PlanSectionText -Config $planCfg -Phase 'Z.9') ''
}
finally {
    Remove-Item -LiteralPath $tmpPlan -Force -ErrorAction SilentlyContinue
}

# A log line per request, shaped like the real stream. Two events for one request_id is
# the normal case for a streamed message and must be counted once, or every number here
# is inflated by however many chunks the message arrived in.
$tmpLog = Join-Path ([System.IO.Path]::GetTempPath()) ("phasekit-log-" + [guid]::NewGuid().ToString('N') + '.log')
$events = @(
    '{"type":"system","subtype":"init","session_id":"s1"}'
    '{"type":"assistant","request_id":"r1","message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":1000,"cache_read_input_tokens":0,"output_tokens":5}}}'
    '{"type":"assistant","request_id":"r1","message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":1000,"cache_read_input_tokens":0,"output_tokens":40}}}'
    '{"type":"assistant","request_id":"r2","message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":500,"cache_read_input_tokens":90000,"output_tokens":20}}}'
    'not json at all, which a log picks up from stderr'
    '{"type":"assistant","request_id":"r3","message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":300,"cache_read_input_tokens":240000,"output_tokens":10}}}'
)
Set-Content -LiteralPath $tmpLog -Value $events

try {
    $spend = Get-LogSpend -LogPath $tmpLog
    Test-Case 'a streamed message is one request, not two' $spend.requests 3
    Test-Case 'peak context is the largest a request carried' $spend.peak 240302
    Test-Case 'the last context is what a live run is sitting at' $spend.last 240302
    Test-Case 'reads are summed once per request' $spend.read 330000
    # 14 fresh + 330000 read at a tenth + 1800 written at 1.25 + 70 out at 5 = 35614
    Test-Case 'the weighting is reads a tenth, writes 1.25, output 5' $spend.weighted 35614

    # The tail is what the dashboard reads on every refresh; it must agree with the whole
    # file about where the context is now, which is the only number it shows.
    Test-Case 'the tail agrees about the current context' (Get-LogSpend -LogPath $tmpLog -TailLines 2).last 240302
    Test-Case 'a log that does not exist is zero, not an error' (Get-LogSpend -LogPath ($tmpLog + '.nope')).requests 0
}
finally {
    Remove-Item -LiteralPath $tmpLog -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Whether a runner is actually running
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'knowing whether a runner is there'

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("phasekit-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$cfg = [pscustomobject]@{ logDir = $tmp; configPath = (Join-Path $tmp 'phasekit.json') }

try {
    Test-Case 'no mark, no runner' ($null -eq (Get-RunnerState -Config $cfg)) $true

    Set-RunnerMark -Config $cfg -Target 'D.1'
    $state = Get-RunnerState -Config $cfg
    Test-Case 'this process reads as alive' $state.alive $true
    Test-Case 'the mark names the target it is on' $state.target 'D.1'

    # The reason two facts are recorded and not one. Windows hands pids out again, and a
    # mark whose number now belongs to something else would report a killed sequence as
    # healthy - the exact lie the mark exists to prevent.
    $mark = Get-Content -LiteralPath (Get-RunnerFile -Config $cfg) -Raw | ConvertFrom-Json
    $mark.pidStart = (Get-Date).AddYears(-3).ToString('o')
    Set-Content -LiteralPath (Get-RunnerFile -Config $cfg) -Value ($mark | ConvertTo-Json)
    Test-Case 'a recycled pid is not evidence of life' (Get-RunnerState -Config $cfg).alive $false

    # A mark from another machine says nothing about a pid here, and must not be read as
    # a death this machine has no way of knowing about.
    $mark.machine = 'some-other-box'
    Set-Content -LiteralPath (Get-RunnerFile -Config $cfg) -Value ($mark | ConvertTo-Json)
    $state = Get-RunnerState -Config $cfg
    Test-Case 'another machine is neither alive nor dead here' "$($state.here)/$($state.alive)" 'False/False'

    # A killed runner leaves its mark behind: that is what makes the death visible at all.
    $mark.machine = [System.Net.Dns]::GetHostName()
    $mark.pid = 999999
    Set-Content -LiteralPath (Get-RunnerFile -Config $cfg) -Value ($mark | ConvertTo-Json)
    Test-Case 'a pid that is gone reads as dead' (Get-RunnerState -Config $cfg).alive $false

    # Clearing is refused for a mark belonging to someone else, so a second runner that
    # declined to start cannot delete the first one's claim on its way out.
    Clear-RunnerMark -Config $cfg
    Test-Case "another process's mark survives Clear-RunnerMark" (Test-Path (Get-RunnerFile -Config $cfg)) $true

    Set-RunnerMark -Config $cfg -Target 'D.1'
    Clear-RunnerMark -Config $cfg
    Test-Case 'a runner clears its own mark' (Test-Path (Get-RunnerFile -Config $cfg)) $false
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails) {
    Write-Host "$fails failed." -ForegroundColor Red
    exit 1
}
Write-Host 'all green.' -ForegroundColor Green
