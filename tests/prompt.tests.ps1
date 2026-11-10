<#
    What a new target's prompt is told before it starts: that the gates already passed on
    the tree it starts from, and what the previous target reported. Both are only worth
    saying when they are true, so most of the cases here are the ones that must say nothing.

        pwsh -NoProfile -File tests/prompt.tests.ps1
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

$root = Join-Path ([IO.Path]::GetTempPath()) ('phasekit-prompt-test-' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $root 'repo'
$logs = Join-Path $root 'logs'
New-Item -ItemType Directory -Path $repo, $logs -Force | Out-Null

try {
    git -C $repo init -q 2>$null
    git -C $repo config user.email 'test@example.invalid'
    git -C $repo config user.name 'test'
    Set-Content -LiteralPath (Join-Path $repo 'a.txt') -Value 'one'
    git -C $repo add -A; git -C $repo commit -q -m 'one' 2>$null

    $cfg = [pscustomobject]@{
        codeDir = $repo; logDir = $logs; skipVerifiedGates = $true; handoff = $true
        gates = @([pscustomobject]@{ name = 'unit'; run = 'echo ok' })
        autoSequence = @('A.1', 'A.2')
    }

    Write-Host 'the gates that already passed'

    Test-Case 'nothing recorded, nothing said' ((Get-GreenGatesNote -Config $cfg) -eq '') 'True'

    Save-GreenGates -Config $cfg
    Test-Case 'green on this exact tree is said' ((Get-GreenGatesNote -Config $cfg) -match 'ALREADY VERIFIED') 'True'

    # A new branch cut from the same commit has the same tree: that is the case it is for.
    git -C $repo checkout -q -b plan/phase-A.2 2>$null
    Test-Case 'a branch cut from the verified tree still counts' ((Get-GreenGatesNote -Config $cfg) -match 'ALREADY VERIFIED') 'True'

    Set-Content -LiteralPath (Join-Path $repo 'a.txt') -Value 'two'
    Test-Case 'an uncommitted change silences it' ((Get-GreenGatesNote -Config $cfg) -eq '') 'True'

    git -C $repo add -A; git -C $repo commit -q -m 'two' 2>$null
    Test-Case 'a different tree silences it' ((Get-GreenGatesNote -Config $cfg) -eq '') 'True'

    Save-GreenGates -Config $cfg
    $cfg.gates = @([pscustomobject]@{ name = 'unit'; run = 'echo changed' })
    Test-Case 'a changed gate list silences it' ((Get-GreenGatesNote -Config $cfg) -eq '') 'True'

    $cfg.gates = @([pscustomobject]@{ name = 'unit'; run = 'echo ok' })
    Test-Case 'the same gate list speaks again' ((Get-GreenGatesNote -Config $cfg) -match 'ALREADY VERIFIED') 'True'

    $cfg.skipVerifiedGates = $false
    Test-Case 'switched off, nothing said' ((Get-GreenGatesNote -Config $cfg) -eq '') 'True'
    $cfg.skipVerifiedGates = $true

    Set-Content -LiteralPath (Join-Path $repo 'b.txt') -Value 'dirty'
    Save-GreenGates -Config $cfg
    Remove-Item -LiteralPath (Join-Path $repo 'b.txt')
    Test-Case 'a dirty tree is never recorded as green' ((Get-Content -LiteralPath (Join-Path $logs 'gates-green.json') -Raw | ConvertFrom-Json).tree -eq ([string] (git -C $repo rev-parse 'HEAD^{tree}')).Trim()) 'True'

    Write-Host ''
    Write-Host 'the handoff from the previous target'

    Test-Case 'no log for the previous target, nothing said' ((Get-HandoffNote -Config $cfg -Phase 'A.2') -eq '') 'True'

    @(
        '{"type":"system","subtype":"init","session_id":"s"}'
        '{"type":"result","subtype":"success","is_error":false,"result":"Committed abc123 feat: the first thing. All gates green.","total_cost_usd":1.0}'
    ) | Set-Content -LiteralPath (Join-Path $logs 'phase-A.1-20261101-100000.log') -Encoding utf8

    $note = Get-HandoffNote -Config $cfg -Phase 'A.2'
    Test-Case 'the previous report is handed on' ($note -match 'Committed abc123') 'True'
    Test-Case 'and named as the previous target''s' ($note -match 'previous target, A\.1') 'True'
    Test-Case 'the first target has nobody before it' ((Get-HandoffNote -Config $cfg -Phase 'A.1') -eq '') 'True'
    Test-Case 'a target outside the sequence gets nothing' ((Get-HandoffNote -Config $cfg -Phase 'Z.9') -eq '') 'True'

    $long = 'x' * 10000
    @(
        '{"type":"system","subtype":"init","session_id":"s"}'
        ('{"type":"result","subtype":"success","is_error":false,"result":"' + $long + ' the end","total_cost_usd":1.0}')
    ) | Set-Content -LiteralPath (Join-Path $logs 'phase-A.1-20261102-100000.log') -Encoding utf8
    $note = Get-HandoffNote -Config $cfg -Phase 'A.2' -MaxChars 3000
    Test-Case 'a long report is bounded' ($note.Length -lt 3600) 'True'
    Test-Case 'and keeps its end' ($note -match 'the end') 'True'

    $cfg.handoff = $false
    Test-Case 'switched off, nothing handed on' ((Get-HandoffNote -Config $cfg -Phase 'A.2') -eq '') 'True'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails -gt 0) { Write-Host "$fails failing" -ForegroundColor Red; exit 1 }
Write-Host 'all green.' -ForegroundColor Green
exit 0
