<#
    How a finished run is classified: usage limit, dropped connection, or stop and show
    the owner. Every case here is one that has actually happened to a sequence.

        pwsh -NoProfile -File tests/classify.tests.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'lib' 'PhaseKit.ps1')

# The verdict the retry loop reaches, from the same two patterns over the same signal.
function Get-Verdict([string] $tail) {
    $signal = Get-LimitSignal -LogTail $tail
    if ($signal -match $script:LimitPattern) { return 'limit' }
    if ($signal -match $script:TransientPattern) { return 'transient' }
    return 'stop'
}

$fails = 0
function Test-Case($name, $tail, $expected) {
    $got = Get-Verdict $tail
    $ok = $got -eq $expected
    if (-not $ok) { $script:fails++ }
    $mark = if ($ok) { 'ok  ' } else { 'FAIL' }
    $colour = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  {0}  {1,-52} -> {2,-9} (expected {3})" -f $mark, $name, $got, $expected) -ForegroundColor $colour
}

Write-Host 'classifying the end of a run'

# The CLI writes its limit banner outside the JSON stream.
Test-Case 'the CLI limit banner' (
    '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}' + "`n" +
    'Claude usage limit reached|resets 10:50pm'
) 'limit'

Test-Case 'a limit announced inside the result record' `
    '{"type":"result","result":"Claude usage limit reached. resets 11pm"}' 'limit'

# This one cost half an hour: a grep of a tracked doc scrolled a 429 past the classifier
# and a crashed run was filed as a spent allowance.
Test-Case 'a 429 quoted inside a tool result' `
    '{"type":"user","message":{"content":[{"type":"tool_result","content":"docs/audit.md:429: rate limit"}]}}' 'stop'

Test-Case 'the connection dropping mid-response' `
    '{"type":"result","subtype":"success","is_error":true,"result":"API Error: Connection closed mid-response. The response above may be incomplete."}' 'transient'

Test-Case 'a 529 from an overloaded upstream' `
    '{"type":"result","result":"API Error: 529 Overloaded"}' 'transient'

# Without the marker this is self-confirming: the note a retry writes is read by the next
# retry as proof of a limit, and the run sleeps its whole budget away on its own voice.
Test-Case 'phasekit''s own note from the previous attempt' (
    '[phasekit] Usage limit reached. Waiting 30 min (fixed interval), resuming at ~22:30 (attempt 1 of 8).' + "`n" +
    '[phasekit]   ... still waiting out the usage limit, 14 min to go (resuming ~22:30)' + "`n" +
    '{"type":"result","result":"API Error: Connection closed mid-response."}'
) 'transient'

# Both of these must reach the owner rather than be retried into silence.
Test-Case 'the agent stopping to ask a question' `
    '{"type":"result","result":"I need a decision before I can continue: which comune?"}' 'stop'

Test-Case 'a red gate' `
    '{"type":"result","result":"pytest failed: 3 tests failed"}' 'stop'

Write-Host ''
if ($fails) {
    Write-Host "$fails failed." -ForegroundColor Red
    exit 1
}
Write-Host 'all green.' -ForegroundColor Green
