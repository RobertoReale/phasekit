<#
    Fast verify mode: which targets are checkpoints, which gates each target merges on,
    what its prompt says, and that a record of green gates still speaks for a target that
    needs fewer of them. Full mode, the default, must behave exactly as before.

        pwsh -NoProfile -File tests/verify.tests.ps1
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

function Get-Names($gates) { return ((@($gates) | ForEach-Object { $_.name }) -join ',') }

$root = Join-Path ([IO.Path]::GetTempPath()) ('phasekit-verify-test-' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $root 'repo'
$logs = Join-Path $root 'logs'
New-Item -ItemType Directory -Path $repo, $logs -Force | Out-Null

try {
    git -C $repo init -q 2>$null
    git -C $repo config user.email 'test@example.invalid'
    git -C $repo config user.name 'test'
    Set-Content -LiteralPath (Join-Path $repo 'a.txt') -Value 'one'
    git -C $repo add -A; git -C $repo commit -q -m 'one' 2>$null

    $unit = [pscustomobject]@{ name = 'unit'; run = 'echo ok' }
    $e2e = [pscustomobject]@{ name = 'e2e'; run = 'echo slow'; slow = $true }
    $cfg = [pscustomobject]@{
        codeDir = $repo; logDir = $logs; skipVerifiedGates = $true; handoff = $false
        configDir = $repo; workingDir = $repo
        verify = 'full'
        gates = @($unit, $e2e)
        autoSequence = @('M1.1', 'M1.2', [pscustomobject]@{ target = 'F.1' }, 'M2.1',
                         [pscustomobject]@{ target = 'M2.2'; checkpoint = $true }, 'M2.3', 'M2.4')
    }

    Write-Host 'full mode, the default'

    Test-Case 'every target is a checkpoint' (Get-GatePlan -Config $cfg -Phase 'M1.1').checkpoint 'True'
    Test-Case 'every gate runs' (Get-Names (Get-GatePlan -Config $cfg -Phase 'M1.1').run) 'unit,e2e'
    Test-Case 'nothing is deferred' @((Get-GatePlan -Config $cfg -Phase 'M1.1').deferred).Count 0
    Test-Case 'the prompt says nothing about it' ((Get-FastModeNote -Config $cfg -Phase 'M1.1') -eq '') 'True'

    Write-Host 'fast mode: where the checkpoints are'

    $cfg.verify = 'fast'
    Test-Case 'a target followed by its milestone is not one' (Get-GatePlan -Config $cfg -Phase 'M1.1').checkpoint 'False'
    Test-Case 'and names the milestone''s last target' (Get-GatePlan -Config $cfg -Phase 'M1.1').next 'M1.2'
    Test-Case 'the last of a milestone is one' (Get-GatePlan -Config $cfg -Phase 'M1.2').checkpoint 'True'
    Test-Case 'a fix task between milestones is one' (Get-GatePlan -Config $cfg -Phase 'F.1').checkpoint 'True'
    Test-Case 'an entry marked checkpoint is one' (Get-GatePlan -Config $cfg -Phase 'M2.2').checkpoint 'True'
    Test-Case 'the target before it points at it' (Get-GatePlan -Config $cfg -Phase 'M2.1').next 'M2.2'
    Test-Case 'after it the milestone runs to its end' (Get-GatePlan -Config $cfg -Phase 'M2.3').next 'M2.4'
    Test-Case 'the last of the sequence is one' (Get-GatePlan -Config $cfg -Phase 'M2.4').checkpoint 'True'
    Test-Case 'an unlisted target is one' (Get-GatePlan -Config $cfg -Phase 'X.9').checkpoint 'True'
    Test-Case 'the milestone of M4.3 is M4' (Get-Milestone 'M4.3') 'M4'
    Test-Case 'the milestone of 2.1.4 is 2.1' (Get-Milestone '2.1.4') '2.1'
    Test-Case 'a dotless id is its own milestone' (Get-Milestone '7') '7'

    Write-Host 'fast mode: which gates run'

    Test-Case 'away from a checkpoint the quick gates run' (Get-Names (Get-GatePlan -Config $cfg -Phase 'M1.1').run) 'unit'
    Test-Case 'and the slow ones wait' (Get-Names (Get-GatePlan -Config $cfg -Phase 'M1.1').deferred) 'e2e'
    Test-Case 'at a checkpoint everything runs' (Get-Names (Get-GatePlan -Config $cfg -Phase 'M1.2').run) 'unit,e2e'
    Test-Case 'Invoke-Gates runs the subset it is given' (Invoke-Gates -Config $cfg -Gates @($unit)) 0
    Test-Case 'an empty subset fails nothing' (Invoke-Gates -Config $cfg -Gates @()) 0
    $bad = [pscustomobject]@{ name = 'bad'; run = 'cmd /c exit 3' }
    $withBad = [pscustomobject]@{ codeDir = $repo; logDir = $logs; configDir = $repo; workingDir = $repo; gates = @($unit, $bad) }
    Test-Case 'a gate left out of the subset is not run' (Invoke-Gates -Config $withBad -Gates @($unit)) 0
    Test-Case 'without -Gates the whole list still runs' (Invoke-Gates -Config $withBad) 1

    Write-Host 'fast mode: what the agent is told'

    $note = Get-FastModeNote -Config $cfg -Phase 'M1.1'
    Test-Case 'a deferring target is told so' ($note -match 'FAST VERIFY MODE') 'True'
    Test-Case 'with the slow gate named' ($note -match '"e2e"') 'True'
    Test-Case 'and where it will run' ($note -match 'run at M1\.2') 'True'
    Test-Case 'a checkpoint is told it closes the milestone' ((Get-FastModeNote -Config $cfg -Phase 'M1.2') -match 'CHECKPOINT') 'True'
    $noSlow = [pscustomobject]@{ verify = 'fast'; gates = @($unit); autoSequence = @('M1.1', 'M1.2') }
    Test-Case 'no slow gate, nothing said' ((Get-FastModeNote -Config $noSlow -Phase 'M1.1') -eq '') 'True'

    Write-Host 'fast mode: the record of green gates'

    # The quick gates passed on this tree: a target that needs only them is covered...
    Save-GreenGates -Config $cfg -Gates @($unit)
    Test-Case 'quick gates green covers a deferring target' ((Get-GreenGatesNote -Config $cfg -Phase 'M1.1') -match 'ALREADY VERIFIED') 'True'
    Test-Case 'and names what was measured' ((Get-GreenGatesNote -Config $cfg -Phase 'M1.1') -match 'needs \(unit\)') 'True'
    # ...and a checkpoint, which needs the slow ones too, is not.
    Test-Case 'but not a checkpoint' ((Get-GreenGatesNote -Config $cfg -Phase 'M1.2') -eq '') 'True'
    Test-Case 'nor a caller that names no target' ((Get-GreenGatesNote -Config $cfg) -eq '') 'True'

    # Every gate passed: that covers any target, a deferring one included.
    Save-GreenGates -Config $cfg -Gates @($unit, $e2e)
    Test-Case 'all green covers a checkpoint' ((Get-GreenGatesNote -Config $cfg -Phase 'M1.2') -match 'every gate in phasekit.json') 'True'
    Test-Case 'and a deferring target' ((Get-GreenGatesNote -Config $cfg -Phase 'M1.1') -match 'ALREADY VERIFIED') 'True'

    # A quick gate whose command changed is a different gate.
    $cfg.gates = @([pscustomobject]@{ name = 'unit'; run = 'echo changed' }, $e2e)
    Test-Case 'a changed quick gate silences it' ((Get-GreenGatesNote -Config $cfg -Phase 'M1.1') -eq '') 'True'
    $cfg.gates = @($unit, $e2e)

    # A record written before per-gate fingerprints existed still counts, for everything.
    [ordered]@{
        tree  = ([string] (git -C $repo rev-parse 'HEAD^{tree}')).Trim()
        gates = (Get-GatesFingerprint -Config $cfg)
        at    = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath (Get-GreenGatesFile -Config $cfg) -Encoding utf8
    Test-Case 'an old record still covers a checkpoint' ((Get-GreenGatesNote -Config $cfg -Phase 'M1.2') -match 'ALREADY VERIFIED') 'True'

    Write-Host 'the setting itself'

    $cfgFile = Join-Path $root 'phasekit.json'
    Set-Content -LiteralPath $cfgFile -Value '{ "gates": [] }'
    Test-Case 'absent, it is full' (Get-PhaseKitConfig -Path $cfgFile).verify 'full'
    Set-Content -LiteralPath $cfgFile -Value '{ "verify": "Fast", "gates": [] }'
    Test-Case 'it is read case-insensitively' (Get-PhaseKitConfig -Path $cfgFile).verify 'fast'
    Set-Content -LiteralPath $cfgFile -Value '{ "verify": "fats", "gates": [] }'
    $threw = $false
    try { $null = Get-PhaseKitConfig -Path $cfgFile } catch { $threw = $_.Exception.Message -match 'must be "full" or "fast"' }
    Test-Case 'a typo is refused, not guessed' $threw 'True'
    Set-Content -LiteralPath $cfgFile -Value '{ "gates": [], "autoSequence": [ { "target": "M1.1", "checkpoint": true }, "M1.2" ] }'
    $seq = @(Get-AutoSequence -Config (Get-PhaseKitConfig -Path $cfgFile))
    Test-Case 'checkpoint is read from an entry' $seq[0].checkpoint 'True'
    Test-Case 'and is false on a bare string' $seq[1].checkpoint 'False'
    $named = @(Get-AutoSequence -Config (Get-PhaseKitConfig -Path $cfgFile) -Targets 'M1.1')
    Test-Case 'and survives naming the target' $named[0].checkpoint 'True'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails -gt 0) { Write-Host "$fails failing" -ForegroundColor Red; exit 1 }
Write-Host 'all green.' -ForegroundColor Green
