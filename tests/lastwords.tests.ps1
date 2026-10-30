<#
    What a stop note quotes as the agent's last message. The verification can only say
    "the branch has no commits on it"; this is the part that says why.

        pwsh -NoProfile -File tests/lastwords.tests.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'lib' 'PhaseKit.ps1')

$fails = 0
function Test-Case($name, $log, $expected) {
    $got = Get-AgentLastWords -LogTail $log
    $ok = $got -ceq $expected
    if (-not $ok) { $script:fails++ }
    $mark = if ($ok) { 'ok  ' } else { 'FAIL' }
    $colour = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  {0}  {1}" -f $mark, $name) -ForegroundColor $colour
    if (-not $ok) { Write-Host "        got:      [$got]`n        expected: [$expected]" -ForegroundColor Red }
}

$prose = { param($t) '{"type":"assistant","message":{"content":[{"type":"text","text":' + ($t | ConvertTo-Json) + '}]}}' }
$result = { param($t) '{"type":"result","subtype":"success","result":' + ($t | ConvertTo-Json) + '}' }

Write-Host 'quoting the agent in a stop note'

Test-Case 'the result record is the final word' (
    (& $prose 'Reading the plan.') + "`n" +
    (& $result 'STOP: task 1.3 assumes a lockfile that is not tracked. Should I create it?')
) 'STOP: task 1.3 assumes a lockfile that is not tracked. Should I create it?'

Test-Case 'a result record beats prose that came after it in the tail' (
    (& $result 'Committed 2.1.') + "`n" + (& $prose 'a resumed turn that never finished')
) 'Committed 2.1.'

# A run killed mid-turn never writes a result record. Its last prose is still the best
# account of where it was.
Test-Case 'no result record: the last assistant prose' (
    (& $prose 'First thought.') + "`n" + (& $prose 'Running the gates now.')
) 'Running the gates now.'

# What the agent read is not what it said: a grep that printed "STOP" from a doc must
# never be quoted as the agent's question.
Test-Case 'tool results are not words the agent said' (
    (& $prose 'Checking the docs.') + "`n" +
    '{"type":"user","message":{"content":[{"type":"tool_result","content":"docs/x.md:1: STOP and ask"}]}}'
) 'Checking the docs.'

Test-Case 'CLI banners, phasekit notes and broken lines are skipped' (
    'Claude usage limit reached|resets 10:50pm' + "`n" +
    '[phasekit] ... still waiting out the usage limit' + "`n" +
    '{"type":"result", truncated' + "`n" +
    (& $prose 'Where I stopped.')
) 'Where I stopped.'

Test-Case 'an empty log has nothing to quote' '' ''

$long = ('x' * 5000) + ' Which one should I keep?'
$got = Get-AgentLastWords -LogTail (& $result $long)
$ok = $got.StartsWith('[...] ') -and $got.EndsWith('Which one should I keep?') -and $got.Length -le 4006
if (-not $ok) { $fails++ }
Write-Host ("  {0}  a long message keeps its end, where the question is" -f $(if ($ok) { 'ok  ' } else { 'FAIL' })) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })

Write-Host ''
if ($fails -gt 0) { Write-Host "$fails failing." -ForegroundColor Red; exit 1 }
Write-Host 'all green.' -ForegroundColor Green
