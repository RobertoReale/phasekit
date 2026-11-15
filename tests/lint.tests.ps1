<#
    phasekit lint and phasekit draft. The lint is checked against a clean plan, against
    each mistake it exists to catch, against the things it must NOT flag (a plan's own
    numbered chapters, a plan in another language), and end to end: `phasekit auto`
    refuses a broken plan before any agent runs.

        pwsh -NoProfile -File tests/lint.tests.ps1
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

$root = Join-Path ([IO.Path]::GetTempPath()) ('phasekit-lint-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$phasekit = Join-Path $PSScriptRoot '..' 'bin' 'phasekit.ps1'

$goodPlan = @'
# Plan

## 1. How this plan is run

### 1.1 The gates

Run the tests.

## 2. PHASE A — First

### A.1 — Do one thing

**Problem.** x

**Done when.** `pytest` passes.

### A.2 — Do another

**Problem.** y

**Done when.** the file exists.

## 9. Ledger

- [x] A.1 Do one thing
- [ ] A.2 Do another
'@
$fence = ([string] [char] 96) * 3
$prompts = "# Prompts`n`n## task`n`n$fence`nDo {{TASK}}.`n$fence`n"

function New-Plan([string] $Name, [string] $Plan, [hashtable] $Settings) {
    $dir = Join-Path $root $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'PLAN.md') -Value $Plan
    Set-Content -LiteralPath (Join-Path $dir 'PROMPTS.md') -Value $prompts
    $cfg = [ordered]@{ plan = 'PLAN.md'; prompts = 'PROMPTS.md'; logDir = 'logs'
        gates = @(@{ name = 'tests'; cwd = '.'; run = 'echo ok' }); autoSequence = @('A.1', 'A.2') }
    foreach ($k in $Settings.Keys) { $cfg[$k] = $Settings[$k] }
    $cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $dir 'phasekit.json')
    return (Get-PhaseKitConfig -Path (Join-Path $dir 'phasekit.json'))
}
function Get-Messages($cfg, [string] $level = 'error') { @(Test-PlanLint -Config $cfg | Where-Object level -eq $level | ForEach-Object { $_.message }) }

try {
    Write-Host 'a clean plan'

    $c = New-Plan 'clean' $goodPlan @{}
    Test-Case 'no findings at all' @(Test-PlanLint -Config $c).Count 0
    Test-Case 'a numbered chapter is not mistaken for a task' (@(Get-Messages $c) -join '') ''

    Write-Host 'the mistakes it exists to catch'

    $c = New-Plan 'no-section' ($goodPlan + "`n- [ ] A.3 A ghost") @{ autoSequence = @('A.1', 'A.2', 'A.3') }
    Test-Case 'a ledger row with no task section' (@(Get-Messages $c) -match 'A\.3 has no task section').Count 1

    $c = New-Plan 'no-row' ($goodPlan -replace '- \[ \] A\.2 Do another', '') @{ autoSequence = @('A.1') }
    Test-Case 'a task with no ledger row' (@(Get-Messages $c) -match 'task A\.2 has no ledger row').Count 1

    $c = New-Plan 'no-done' ($goodPlan -replace '\*\*Done when\.\*\* the file exists\.', 'Some prose.') @{}
    Test-Case 'a task with no Done when' (@(Get-Messages $c) -match "A\.2 has no 'Done when'").Count 1

    $c = New-Plan 'dup-row' ($goodPlan + "`n- [ ] A.2 Do another") @{}
    Test-Case 'a ledger row listed twice' (@(Get-Messages $c) -match 'A\.2 appears twice').Count 1

    $c = New-Plan 'unknown' $goodPlan @{ autoSequence = @('A.1', 'A.2', 'B.7') }
    Test-Case 'a sequence naming a target the plan lacks' (@(Get-Messages $c) -match 'names B\.7').Count 1

    $c = New-Plan 'twice' $goodPlan @{ autoSequence = @('A.1', 'A.2', 'A.2') }
    Test-Case 'a target listed twice in the sequence' (@(Get-Messages $c) -match 'lists A\.2 twice').Count 1

    $c = New-Plan 'unreached' $goodPlan @{ autoSequence = @('A.1') }
    Test-Case 'an unticked task the sequence never reaches' (@(Get-Messages $c) -match 'A\.2 is not done and autoSequence never reaches').Count 1
    Test-Case 'a ticked one is fine out of the sequence' (@(Get-Messages $c) -match 'A\.1 is not done').Count 0

    $c = New-Plan 'phase-target' $goodPlan @{ autoSequence = @('A') }
    Test-Case 'a phase target covers its tasks' @(Get-Messages $c).Count 0

    $c = New-Plan 'placeholder' $goodPlan @{ gates = @(@{ name = 'tests'; cwd = '.'; run = 'echo replace me' }) }
    Test-Case 'the template''s placeholder gate' (@(Get-Messages $c) -match 'placeholder').Count 1

    $c = New-Plan 'no-gates' $goodPlan @{ gates = @() }
    Test-Case 'no gates is a warning' (@(Get-Messages $c 'warning') -match 'no gates').Count 1
    $c = New-Plan 'gate-dir' $goodPlan @{ gates = @(@{ name = 'web'; cwd = 'frontend'; run = 'npm test' }) }
    Test-Case 'a gate directory not there yet is a warning, not an error' "$((@(Get-Messages $c 'warning') -match 'frontend').Count)/$(@(Get-Messages $c).Count)" '1/0'

    $c = New-Plan 'no-prompt' $goodPlan @{}
    Set-Content -LiteralPath $c.prompts -Value '# Prompts, none usable'
    Test-Case 'a target with no prompt block is a warning' (@(Get-Messages $c 'warning') -match 'no prompt block for A\.1').Count 1

    $c = New-Plan 'no-plan' $goodPlan @{}
    Remove-Item -LiteralPath $c.plan
    Test-Case 'a missing plan is an error' (@(Get-Messages $c) -match 'does not exist').Count 1

    Write-Host 'a plan in another language'

    $italian = $goodPlan -replace '\*\*Done when\.\*\*', '**Fatto quando.**'
    $c = New-Plan 'italian' $italian @{}
    Test-Case 'with the default label it is flagged' (@(Get-Messages $c) -match "no 'Done when'").Count 2
    $c = New-Plan 'italian-ok' $italian @{ planSections = @('Fatto quando') }
    Test-Case 'with its own label it checks out' @(Get-Messages $c).Count 0

    Write-Host 'the commands'

    $c = New-Plan 'cli-good' $goodPlan @{}
    $null = & pwsh -NoProfile -File $phasekit lint -Config (Join-Path $root 'cli-good' 'phasekit.json') 2>&1
    Test-Case 'phasekit lint exits 0 on a clean plan' $LASTEXITCODE 0
    $c = New-Plan 'cli-bad' ($goodPlan + "`n- [ ] A.3 A ghost") @{}
    $null = & pwsh -NoProfile -File $phasekit lint -Config (Join-Path $root 'cli-bad' 'phasekit.json') 2>&1
    Test-Case 'and 1 when there is an error' $LASTEXITCODE 1
    Set-Content -LiteralPath (Join-Path $root 'cli-bad' 'phasekit.json') -Value '{ "verify": "fats" }'
    $out = & pwsh -NoProfile -File $phasekit lint -Config (Join-Path $root 'cli-bad' 'phasekit.json') 2>&1
    Test-Case 'a broken phasekit.json is reported, not thrown' "$LASTEXITCODE/$([bool](($out -join ' ') -match 'verify'))" '1/True'

    # auto refuses a broken plan before any agent runs: the fake claude records every call.
    $repo = Join-Path $root 'auto-refuses'
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    git -C $repo init -q -b main 2>$null
    git -C $repo config user.email 'test@example.invalid'; git -C $repo config user.name 'test'
    Set-Content -LiteralPath (Join-Path $repo 'PLAN.md') -Value ($goodPlan + "`n- [ ] A.3 A ghost")
    Set-Content -LiteralPath (Join-Path $repo 'PROMPTS.md') -Value $prompts
    Set-Content -LiteralPath (Join-Path $repo '.gitignore') -Value "logs/`nfake/`nhome/`n"
    @{ plan = 'PLAN.md'; prompts = 'PROMPTS.md'; logDir = 'logs'; notify = $false
       gates = @(@{ name = 'tests'; cwd = '.'; run = 'echo ok' }); autoSequence = @('A.1', 'A.2', 'A.3') } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $repo 'phasekit.json')
    git -C $repo add -A 2>$null; git -C $repo commit -q -m start 2>$null
    $fake = Join-Path $repo 'fake'; New-Item -ItemType Directory -Path $fake -Force | Out-Null
    $saved = @{ PATH = $env:PATH; PK_FAKE_DIR = $env:PK_FAKE_DIR; PHASEKIT_HOME = $env:PHASEKIT_HOME }
    $env:PATH = (Join-Path $PSScriptRoot 'fake-claude') + [IO.Path]::PathSeparator + $env:PATH
    $env:PK_FAKE_DIR = $fake; $env:PHASEKIT_HOME = Join-Path $repo 'home'
    try { $null = & pwsh -NoProfile -File $phasekit auto -Config (Join-Path $repo 'phasekit.json') 2>&1; $code = $LASTEXITCODE }
    finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
    $stop = Join-Path $repo 'logs' 'auto-stopped.txt'
    Test-Case 'auto refuses a broken plan' $code 1
    Test-Case 'without calling any agent' (Test-Path (Join-Path $fake 'calls.txt')) 'False'
    Test-Case 'and the stop note says why' ((Get-Content -LiteralPath $stop -Raw) -match 'A\.3 has no task section') 'True'

    $out = & pwsh -NoProfile -File $phasekit draft -DryRun -Text 'una app per le note' 2>&1
    $text = $out -join "`n"
    Test-Case 'draft: the person''s words reach the prompt' ($text -match 'una app per le note') 'True'
    Test-Case 'draft: it talks in their language, writes in English' (($text -match 'language they write to you in') -and ($text -match 'Write every file in English')) 'True'
    Test-Case 'draft: it ends by linting what it wrote' ($text -match 'phasekit\.ps1" lint') 'True'
    Test-Case 'draft: the plan''s own placeholders survive' ($text -match '\{\{TASK\}\}') 'True'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails -gt 0) { Write-Host "$fails failing" -ForegroundColor Red; exit 1 }
Write-Host 'all green.' -ForegroundColor Green
