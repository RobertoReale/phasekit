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
# Saying which gate failed
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'what a stop note can say'

$gateDir = Join-Path ([System.IO.Path]::GetTempPath()) ("phasekit-gates-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $gateDir -Force | Out-Null

try {
    $gateCfg = [pscustomobject]@{
        configDir  = $gateDir
        workingDir = $gateDir
        gates      = @(
            [pscustomobject]@{ name = 'tests'; cwd = '.'; run = 'cmd /c exit 0' }
            [pscustomobject]@{ name = 'browser suite'; cwd = '.'; run = 'cmd /c exit 3' }
            [pscustomobject]@{ name = 'nowhere'; cwd = 'no-such-dir'; run = 'cmd /c exit 0' }
        )
    }

    $failed = Invoke-Gates -Config $gateCfg
    Test-Case 'the count is still what Invoke-Gates returns' $failed 2

    $f = @(Get-LastGateFailures)
    Test-Case 'only the failures are remembered' $f.Count 2
    Test-Case 'a failure keeps its name' $f[0].name 'browser suite'
    Test-Case 'a failure keeps its exit code' $f[0].code 3
    Test-Case 'a missing directory is a failure too' $f[1].name 'nowhere'

    # This string is the whole point: it is what somebody reads hours later, out of a file,
    # with no terminal and no memory of what was running.
    Test-Case 'the stop note names them' `
        (Format-GateFailures -Failures $f) `
        '2 gate(s) failing on the branch: browser suite (exit 3), nowhere (exit -1)'

    # A green run must clear the previous one, or the next stop quotes a failure that has
    # since been fixed - which is worse than saying nothing.
    $green = [pscustomobject]@{
        configDir = $gateDir; workingDir = $gateDir
        gates = @([pscustomobject]@{ name = 'tests'; cwd = '.'; run = 'cmd /c exit 0' })
    }
    $null = Invoke-Gates -Config $green
    Test-Case 'a green run forgets the last failures' @(Get-LastGateFailures).Count 0
    Test-Case 'nothing failing is said plainly' `
        (Format-GateFailures -Failures (Get-LastGateFailures)) `
        'the merge preconditions failed on the branch'

    # A gate that is allowed to be disturbed. `retries` is opt-in and off everywhere it
    # is not written down: a failing test is not worth running twice, and a gate that
    # quietly does turns a real regression into a coin toss.
    $ranOnce = Join-Path $gateDir 'ran-once'
    $flaky = "if (Test-Path '$ranOnce') { " + '$global:LASTEXITCODE = 0' + " } else { " +
             "New-Item -ItemType File '$ranOnce' | Out-Null; " + '$global:LASTEXITCODE = 1' + " }"

    $once = [pscustomobject]@{
        configDir = $gateDir; workingDir = $gateDir
        gates = @([pscustomobject]@{ name = 'browser suite'; cwd = '.'; run = $flaky })
    }
    Test-Case 'a gate without retries fails on the first refusal' (Invoke-Gates -Config $once) 1

    Remove-Item -LiteralPath $ranOnce -Force
    $twice = [pscustomobject]@{
        configDir = $gateDir; workingDir = $gateDir
        gates = @([pscustomobject]@{ name = 'browser suite'; cwd = '.'; run = $flaky; retries = 1 })
    }
    Test-Case 'a gate that asked for one retry gets it' (Invoke-Gates -Config $twice) 0

    # The retry is a second chance, not an exemption.
    $never = [pscustomobject]@{
        configDir = $gateDir; workingDir = $gateDir
        gates = @([pscustomobject]@{ name = 'browser suite'; cwd = '.'; run = 'cmd /c exit 3'; retries = 2 })
    }
    Test-Case 'a gate that refuses every time fails with retries too' (Invoke-Gates -Config $never) 1
    Test-Case 'and reports the exit code it really gave' @(Get-LastGateFailures)[0].code 3
}
finally {
    Remove-Item -LiteralPath $gateDir -Recurse -Force -ErrorAction SilentlyContinue
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

# ---------------------------------------------------------------------------
# Restarting a runner that was killed, and knowing when to stop trying
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'watching a runner that died'

$wd = Join-Path ([System.IO.Path]::GetTempPath()) ("phasekit-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $wd -Force | Out-Null
$cfg = [pscustomobject]@{ logDir = $wd; configPath = (Join-Path $wd 'phasekit.json') }

# Rewrites the mark on disk to describe a process that is not there. A killed runner
# leaves exactly this behind, and it is the only state a watchdog may act on.
function Set-DeadMark {
    Set-RunnerMark -Config $cfg -Target 'E.2'
    $m = Get-Content -LiteralPath (Get-RunnerFile -Config $cfg) -Raw | ConvertFrom-Json
    $m.pid = 999999
    Set-Content -LiteralPath (Get-RunnerFile -Config $cfg) -Value ($m | ConvertTo-Json)
}

try {
    Test-Case 'nothing to watch when no sequence is running' `
        (Invoke-WatchdogCheck -Config $cfg).action 'idle'

    # A sequence that stopped on purpose clears its mark, so it reads as idle too - which
    # is the whole reason the watchdog can be this simple and never relaunches a stop that
    # was asking for a person.
    Set-Content -LiteralPath (Join-Path $wd 'auto-stopped.txt') -Value 'stopped at E.2'
    Test-Case 'a deliberate stop is not a death' (Invoke-WatchdogCheck -Config $cfg).action 'idle'

    Set-RunnerMark -Config $cfg -Target 'E.2'
    Test-Case 'a live runner is left alone' (Invoke-WatchdogCheck -Config $cfg).action 'running'

    $m = Get-Content -LiteralPath (Get-RunnerFile -Config $cfg) -Raw | ConvertFrom-Json
    $m.machine = 'some-other-box'
    Set-Content -LiteralPath (Get-RunnerFile -Config $cfg) -Value ($m | ConvertTo-Json)
    Test-Case 'another machine is not this one to restart' `
        (Invoke-WatchdogCheck -Config $cfg).action 'elsewhere'

    Set-DeadMark
    $v = Invoke-WatchdogCheck -Config $cfg
    Test-Case 'a killed runner is restarted' $v.action 'restart'
    Test-Case 'and the verdict names the target it died on' $v.target 'E.2'

    Set-DeadMark
    Test-Case 'a second death still earns a restart' (Invoke-WatchdogCheck -Config $cfg).action 'restart'
    Set-DeadMark
    Test-Case 'and a third' (Invoke-WatchdogCheck -Config $cfg).action 'restart'

    # Three restarts inside the window is a fault a fourth will not fix. Each one costs a
    # session, so the watchdog stops paying for the same answer.
    Set-DeadMark
    $v = Invoke-WatchdogCheck -Config $cfg
    Test-Case 'a run that keeps dying is given up on' $v.action 'given-up'
    Test-Case 'and it says how many times it tried' $v.restarts 3

    # The same three deaths, spread over a week, are three unrelated accidents.
    Set-Content -LiteralPath (Get-WatchdogFile -Config $cfg) -Value (
        [ordered]@{ restarts = @(1, 2, 3 | ForEach-Object {
            (Get-Date).AddDays(-$_).ToString('o') }) } | ConvertTo-Json)
    Set-DeadMark
    Test-Case 'deaths outside the window are not a pattern' `
        (Invoke-WatchdogCheck -Config $cfg).action 'restart'
}
finally {
    Remove-Item -LiteralPath $wd -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# The stop that answers itself
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'a task that ended without committing'

function New-Report([bool] $ok, [string[]] $problems) {
    return [pscustomobject]@{ ok = $ok; problems = [System.Collections.Generic.List[string]] $problems }
}

Test-Case 'a phase that verified is not a stop at all' `
    (Test-UnfinishedWorkStop -Report (New-Report $true @())) $false

Test-Case 'work on disk and no commit is the case it exists for' `
    (Test-UnfinishedWorkStop -Report (New-Report $false @(
        '20 uncommitted change(s) - a task ended without committing',
        'the branch has no commits on it'))) $true

Test-Case 'work on disk over commits already made still counts' `
    (Test-UnfinishedWorkStop -Report (New-Report $false @(
        '3 uncommitted change(s) - a task ended without committing'))) $true

# Nothing to save means nothing to tell it to save, and the reason the phase produced
# nothing is exactly the thing nobody has established yet.
Test-Case 'an empty branch with a clean tree is a question, not this' `
    (Test-UnfinishedWorkStop -Report (New-Report $false @('the branch has no commits on it'))) $false

Test-Case 'a branch that is not there is a question' `
    (Test-UnfinishedWorkStop -Report (New-Report $false @('branch plan/phase-G.10 does not exist'))) $false

Test-Case 'the wrong branch checked out is a question' `
    (Test-UnfinishedWorkStop -Report (New-Report $false @(
        '20 uncommitted change(s) - a task ended without committing',
        'not on plan/phase-G.10 (currently on master)'))) $false

Test-Case 'a ledger that disagrees is a question' `
    (Test-UnfinishedWorkStop -Report (New-Report $false @(
        '2 uncommitted change(s) - a task ended without committing',
        '1 task(s) in this phase not ticked: G.10 confirm the search'))) $false

$answer = Get-UnfinishedWorkAnswer -Target 'G.10'
Test-Case 'the answer names the target it is for' ($answer -match 'G\.10') $true
Test-Case 'it says to run the gates in the foreground' ($answer -match 'FOREGROUND') $true
Test-Case 'it says the work is still there' ($answer -match 'Nothing is lost') $true

# ---------------------------------------------------------------------------
# Reading a failure out of a gate's output
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'what a failing gate leaves in the stop note'

# The shape that produced the empty stop note: vitest prints the failure where it happens
# and the counts at the end, so the tail of a red run is a list of tests that passed.
$vitest = @(
    ' RUN  v3.2.4'
    ''
    ' FAIL  src/lib/propertyParams.test.ts > round-trips a price range'
    'AssertionError: expected 250000 to be 25000'
    '  - Expected: 25000'
    '  + Received: 250000'
    ' at src/lib/propertyParams.test.ts:41:22'
    ''
) + (1..40 | ForEach-Object { "  ok  src/routes/thing$_.test.tsx (3 tests) 12ms" }) + @(
    ' Test Files  1 failed | 50 passed (51)'
    '      Tests  1 failed | 457 passed (458)'
    '   Duration  68.11s'
)

$picked = Select-FailureLines -Output $vitest

# The whole point: the name of what broke survives the trip into auto-stopped.txt.
Test-Case 'the failing test is named' ($picked -match 'round-trips a price range') $true
Test-Case 'the assertion comes with it' ($picked -match 'expected 250000 to be 25000') $true
Test-Case 'so does what was expected' ($picked -match 'Expected: 25000') $true
Test-Case 'and the counts at the end' ($picked -match '1 failed \| 457 passed') $true
Test-Case 'the forty passing tests in between do not' ($picked -match 'thing20') $false
Test-Case 'the cut is marked, not silent' ($picked -match '\.\.\.') $true

# The old behaviour, kept for anything this vocabulary does not recognise.
$unknown = 1..30 | ForEach-Object { "line $_" }
$tailOnly = Select-FailureLines -Output $unknown -Tail 8
Test-Case 'output with no marker falls back to the tail' `
    (($tailOnly -split "`n").Count) 8
Test-Case 'and it is the end of it' ($tailOnly -match 'line 30') $true

# Colour codes are in front of every anchor, and in the note nobody can read past them.
$coloured = @("$([char] 27)[31m FAIL  src/x.test.ts > it adds$([char] 27)[39m", 'AssertionError: nope')
$clean = Select-FailureLines -Output $coloured
Test-Case 'colour codes are stripped' ($clean -match '\[31m') $false
Test-Case 'the line survives the stripping' ($clean -match 'FAIL  src/x.test.ts') $true

Test-Case 'pytest failures are recognised' `
    ((Select-FailureLines -Output @('FAILED tests/test_scan.py::test_dedup - assert 2 == 1')) -match 'test_dedup') $true
Test-Case 'a type error is recognised' `
    ((Select-FailureLines -Output @("src/App.tsx(12,5): error TS2304: Cannot find name 'foo'")) -match 'TS2304') $true

Test-Case 'nothing at all is not a crash' (Select-FailureLines -Output @()) ''
Test-Case 'a null output is not a crash' (Select-FailureLines -Output $null) ''

# ---------------------------------------------------------------------------
# A pinned session that is not there any more
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'resuming a conversation the machine no longer has'

Test-Case 'the sentence claude prints is recognised' `
    (Test-DeadSession -LogTail 'No conversation found with session ID: cbb679d3-296a-4cb2-8055-e1a0080c68a4') $true

Test-Case 'it is recognised inside a log tail' `
    (Test-DeadSession -LogTail ("some earlier line" + "`n" + "No conversation found with session ID: abc" + "`n" + '{"type":"result"}')) $true

# It must not swallow the failures that ARE worth retrying, or a dropped connection would
# cost the pin as well as the attempt.
Test-Case 'a dropped connection is not this' `
    (Test-DeadSession -LogTail 'API Error: Connection reset by peer') $false

Test-Case 'a usage limit is not this' `
    (Test-DeadSession -LogTail 'Claude usage limit reached. Your limit resets at 3am') $false

Test-Case 'an empty log is not this' (Test-DeadSession -LogTail '') $false

# The two classifications have to disagree here, because the retry loop asks this one
# first and a yes to both would send a dead session round the transient path.
Test-Case 'a dead session is not classified as transient' `
    (Test-TransientFailure -LogTail 'No conversation found with session ID: abc') $false

# ---------------------------------------------------------------------------
# The journal a sequence writes about itself
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'the progress journal'

$jd = Join-Path ([IO.Path]::GetTempPath()) ("pk-journal-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $jd | Out-Null
try {
    $jcfg = [pscustomobject]@{ logDir = $jd }

    # Silence before a sequence opens one: a hand-run `phasekit gates` must not write into
    # the record of a run that is not happening.
    Close-AutoJournal
    Write-AutoProgress 'this should go nowhere'
    Test-Case 'nothing is written before a sequence opens one' `
        (Test-Path (Get-AutoJournalFile -Config $jcfg)) $false

    Open-AutoJournal -Config $jcfg
    Write-AutoProgress 'G.10 starting'
    $lines = @(Get-Content -LiteralPath (Get-AutoJournalFile -Config $jcfg))
    Test-Case 'opening it says the sequence started' ($lines[0] -match 'sequence started') $true
    Test-Case 'a line lands after it' ($lines[-1] -match 'G\.10 starting') $true
    Test-Case 'every line is timestamped' ($lines[-1] -match '^\d\d:\d\d:\d\d  ') $true

    # A second sequence starts from an empty journal - what is in it is what is happening
    # now, not a scroll back through last week.
    Open-AutoJournal -Config $jcfg
    Test-Case 'the next sequence truncates it' `
        (@(Get-Content -LiteralPath (Get-AutoJournalFile -Config $jcfg))).Count 1

    Close-AutoJournal
    Write-AutoProgress 'after the sequence ended'
    Test-Case 'closing it stops the writing' `
        (@(Get-Content -LiteralPath (Get-AutoJournalFile -Config $jcfg))).Count 1
}
finally {
    Close-AutoJournal
    Remove-Item -LiteralPath $jd -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Dating a log by its own clock
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'reading back a log that is hours old'

function Get-Rendered([string[]] $Lines) {
    Reset-StreamClock
    return (& { foreach ($l in $Lines) { Write-StreamLine -Line $l } } 6>&1 | Out-String)
}

$old = '2020-01-02T03:04:05.000Z'
$stamped = ([datetime] $old).ToLocalTime().ToString('HH:mm:ss')

# The result event carries no timestamp of its own, which is why it used to be dated by
# the clock of whoever was reading the log rather than by the run that produced it.
$rendered = Get-Rendered @(
    '{"type":"assistant","timestamp":"' + $old + '","message":{"content":[{"type":"text","text":"working"}]}}'
    '{"type":"result","subtype":"success","is_error":false,"num_turns":7}'
)
Test-Case 'a finished run is dated by the log, not by now' ($rendered -match ($stamped + '  DONE')) $true
Test-Case 'and it still says it is done' ($rendered -match 'turns=7') $true

# The log that started all this: a resume of a session that no longer exists. It used to
# render as a green DONE with turns=0, which reads as a phase that had nothing to do.
$dead = Get-Rendered @(
    'No conversation found with session ID: cbb679d3'
    '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":0,' +
        '"errors":["No conversation found with session ID: cbb679d3"]}'
)
Test-Case 'a failed run does not say DONE' ($dead -match 'DONE') $false
Test-Case 'it says FAILED' ($dead -match 'FAILED') $true
Test-Case 'it names the subtype' ($dead -match 'error_during_execution') $true
Test-Case 'and it prints the error itself' ($dead -match 'No conversation found') $true

# ---------------------------------------------------------------------------
# Whether a target has actually landed
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'deciding that a target is done'

$MAIN = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$OWN  = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

function New-Snapshot {
    param(
        [string[]] $Plan,
        [hashtable] $Tips = @{},
        [string[]] $Merged = @(),
        [switch] $NoPlan
    )
    $branches = @{}
    foreach ($k in $Tips.Keys) { $branches[$k] = $true }
    $mergedMap = @{}
    foreach ($m in $Merged) { $mergedMap[$m] = $true }
    return [pscustomobject]@{
        main = 'master'; mainTip = $MAIN
        branches = $branches; tips = $Tips; merged = $mergedMap; ahead = @{}
        hasPlan = (-not $NoPlan); planLines = $Plan
    }
}

$cfgD = [pscustomobject]@{ branchPrefix = 'plan/phase-'; plan = 'nowhere.md'; codeDir = '.' }
$ticked   = @('- [x] G.6 say which portals answered')
$unticked = @('- [ ] G.6 say which portals answered')

# The shape that cost a morning: the agent ticked the ledger and ended without ever
# committing, so its branch still pointed exactly where master did. `git branch --merged`
# calls such a branch contained - containing nothing is trivially true - and the sequence
# read "ticked and merged", skipped the verify entirely and walked on to the next target,
# whose first act is to demand a clean tree.
Test-Case 'a ticked ledger over a branch that never got a commit is not done' `
    (Test-TargetDone -Config $cfgD -Target 'G.6' -Snapshot (New-Snapshot -Plan $ticked `
        -Tips @{ 'plan/phase-G.6' = $MAIN } -Merged @('plan/phase-G.6'))) $false

# ...and the case it must not break: a branch that really landed. --no-ff puts the merge
# commit on top, so master moves and the branch keeps its own tip.
Test-Case 'a branch that really merged is done' `
    (Test-TargetDone -Config $cfgD -Target 'G.6' -Snapshot (New-Snapshot -Plan $ticked `
        -Tips @{ 'plan/phase-G.6' = $OWN } -Merged @('plan/phase-G.6'))) $true

Test-Case 'a merged branch tidied away is still done' `
    (Test-TargetDone -Config $cfgD -Target 'G.6' -Snapshot (New-Snapshot -Plan $ticked)) $true

Test-Case 'a branch with its own commits that has not merged is not done' `
    (Test-TargetDone -Config $cfgD -Target 'G.6' -Snapshot (New-Snapshot -Plan $ticked `
        -Tips @{ 'plan/phase-G.6' = $OWN })) $false

Test-Case 'an unticked ledger is not done whatever the branch says' `
    (Test-TargetDone -Config $cfgD -Target 'G.6' -Snapshot (New-Snapshot -Plan $unticked `
        -Tips @{ 'plan/phase-G.6' = $OWN } -Merged @('plan/phase-G.6'))) $false

# A target declared to produce no commit ends with an empty branch on purpose, so the
# guard has to stand down for it or the sequence would run it again for ever.
Test-Case 'an empty branch is the expected ending when no commit was promised' `
    (Test-TargetDone -Config $cfgD -Target 'G.6' -AllowNoCommits -Snapshot (New-Snapshot -Plan $ticked `
        -Tips @{ 'plan/phase-G.6' = $MAIN } -Merged @('plan/phase-G.6'))) $true

# With no plan the repository alone decides, and an empty branch is still not evidence
# that anything happened.
Test-Case 'no plan, an empty branch is still not done' `
    (Test-TargetDone -Config $cfgD -Target 'G.6' -Snapshot (New-Snapshot -NoPlan `
        -Tips @{ 'plan/phase-G.6' = $MAIN } -Merged @('plan/phase-G.6'))) $false

Test-Case 'no plan and no branch is not done' `
    (Test-TargetDone -Config $cfgD -Target 'G.6' -Snapshot (New-Snapshot -NoPlan)) $false

# A snapshot from before tips were recorded must not start reporting everything undone.
$old = New-Snapshot -Plan $ticked -Tips @{ 'plan/phase-G.6' = $MAIN } -Merged @('plan/phase-G.6')
$old.PSObject.Properties.Remove('tips')
$old.PSObject.Properties.Remove('mainTip')
Test-Case 'a snapshot without tips falls back to the old answer' `
    (Test-TargetDone -Config $cfgD -Target 'G.6' -Snapshot $old) $true

Write-Host ''
if ($fails) {
    Write-Host "$fails failed." -ForegroundColor Red
    exit 1
}
Write-Host 'all green.' -ForegroundColor Green
