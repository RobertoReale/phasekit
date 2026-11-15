<#
    How a run is rendered: the compact view (the default, live and in `phasekit logs`) and
    the detailed one (`phasekit logs -Full`).

        pwsh -NoProfile -File tests/stream.tests.ps1
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

# Write-Host goes to the information stream; 6>&1 brings it back as text to look at.
function Get-Rendered([string] $Line, [bool] $Full) {
    $script:StreamFull = $Full
    try { return ((Write-StreamLine -Line $Line 6>&1) | ForEach-Object { "$_" }) -join "`n" }
    finally { $script:StreamFull = $false }
}

$long = 'pnpm vitest run tests/unit/a-very-long-file-name-that-goes-on.test.ts --reporter verbose --coverage --run-in-band --and-more-flags'
$use = @{ type = 'assistant'; timestamp = '2026-11-15T12:00:00Z'; message = @{ content = @(
            @{ type = 'thinking'; thinking = '' }
            @{ type = 'tool_use'; name = 'Bash'; input = @{ command = $long; description = 'Run one test file' } }
        ) } } | ConvertTo-Json -Depth 6 -Compress
$edit = @{ type = 'assistant'; message = @{ content = @(
            @{ type = 'tool_use'; name = 'Edit'; input = @{ file_path = 'src/a.ts'; old_string = "return a - b;"; new_string = "return a + b;" } }
        ) } } | ConvertTo-Json -Depth 6 -Compress
$result = @{ type = 'user'; message = @{ content = @(
            @{ type = 'tool_result'; content = ((1..30 | ForEach-Object { "line $_" }) -join "`n") }
        ) } } | ConvertTo-Json -Depth 6 -Compress
$failure = @{ type = 'user'; message = @{ content = @(
            @{ type = 'tool_result'; is_error = $true; content = @(@{ type = 'text'; text = 'Exit code 1' }) }
        ) } } | ConvertTo-Json -Depth 6 -Compress

Write-Host 'the compact view'

$c = Get-Rendered $use $false
Test-Case 'a long command is cut' ($c -match '\.\.\.$') 'True'
Test-Case 'thinking is not shown' ($c -match 'thinking') 'False'
Test-Case 'tool output is not shown' ((Get-Rendered $result $false) -eq '') 'True'

Write-Host 'the detailed view'

$f = Get-Rendered $use $true
Test-Case 'the whole command is there' ($f -match [regex]::Escape('--and-more-flags')) 'True'
Test-Case 'with its description' ($f -match 'Run one test file') 'True'
Test-Case 'thinking is marked' ($f -match '\(thinking\)') 'True'
$e = Get-Rendered $edit $true
Test-Case 'an edit shows what goes' ($e -match '- return a - b;') 'True'
Test-Case 'and what comes' ($e -match '\+ return a \+ b;') 'True'
$r = Get-Rendered $result $true
Test-Case 'tool output is shown, its head' ($r -match '\| line 12') 'True'
Test-Case 'and not its tail' ($r -match '\| line 13') 'False'
Test-Case 'saying how much was left out' ($r -match '18 more line') 'True'
Test-Case 'an error result is shown' ((Get-Rendered $failure $true) -match 'Exit code 1') 'True'
Test-Case 'the flag does not leak into the next render' ($script:StreamFull) 'False'

Write-Host ''
if ($fails -gt 0) { Write-Host "$fails failing" -ForegroundColor Red; exit 1 }
Write-Host 'all green.' -ForegroundColor Green
