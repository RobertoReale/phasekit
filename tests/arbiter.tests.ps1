<#
    The arbiter: a target that stops with a question is answered by an independent
    read-only model when the answer is technical, and reaches a person otherwise. Unit
    cases first, then `phasekit auto` end to end against the fake claude.

        pwsh -NoProfile -File tests/arbiter.tests.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'lib' 'PhaseKit.ps1')

$fails = 0
function Test-Case($name, $got, $expected) {
    $ok = "$got" -eq "$expected"
    if (-not $ok) { $script:fails++ }
    $mark = if ($ok) { 'ok  ' } else { 'FAIL' }
    $colour = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  {0}  {1,-60} -> {2} (expected {3})" -f $mark, $name, $got, $expected) -ForegroundColor $colour
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('phasekit-arbiter-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$phasekit = Join-Path $PSScriptRoot '..' 'bin' 'phasekit.ps1'
$fakeBin = Join-Path $PSScriptRoot 'fake-claude'

try {
    Write-Host 'reading a decision'
    $d = ConvertFrom-ArbiterDecision -Text "I read it.`n`nDECISION: ANSWER`nTake option (a); finish, run the gates, commit."
    Test-Case 'an answer' "$($d.decision)|$($d.text)" 'ANSWER|Take option (a); finish, run the gates, commit.'
    $d = ConvertFrom-ArbiterDecision -Text "The format is DECISION: ANSWER or ...`n**DECISION: ESCALATE**`nA product choice."
    Test-Case 'only the last line counts, markdown and all' "$($d.decision)|$($d.text)" 'ESCALATE|A product choice.'
    Test-Case 'an empty answer answers nothing' (ConvertFrom-ArbiterDecision -Text "DECISION: ANSWER`nok").decision 'NONE'
    Test-Case 'no decision line, no decision' (ConvertFrom-ArbiterDecision -Text 'Thoughts.').decision 'NONE'

    Write-Host 'the prompt'
    $cfgDir = Join-Path $root 'cfg'
    New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $cfgDir 'PLAN.md') -Value "# Plan`n`n### A.1 - Budget`n`n**Done when.** under 15 KB`n"
    Set-Content -LiteralPath (Join-Path $cfgDir 'phasekit.json') -Value '{ "plan": "PLAN.md", "gates": [] }'
    $c = Get-PhaseKitConfig -Path (Join-Path $cfgDir 'phasekit.json')
    Test-Case 'off by default' "$($c.arbiter)|$($c.arbiterModel)|$($c.arbiterEffort)" 'False|opus|high'
    $p = Get-ArbiterPrompt -Config $c -Target 'A.1' -Problems 'no commits' -Question 'Option (a) or (b)?'
    Test-Case 'it carries the question' ($p -match 'Option \(a\) or \(b\)\?') 'True'
    Test-Case 'and the task, quoted' ($p -match 'under 15 KB') 'True'
    Test-Case 'and the line it may not cross' ($p -match 'lowers no bar' -and $p -match 'When in doubt, escalate') 'True'
    Set-Content -LiteralPath (Join-Path $cfgDir 'phasekit.json') -Value '{ "plan": "PLAN.md", "arbiter": true, "arbiterModel": "agy:gemini-4-hydrogen-high", "gates": [] }'
    $c = Get-PhaseKitConfig -Path (Join-Path $cfgDir 'phasekit.json')
    Test-Case 'any model, Antigravity too' "$($c.arbiter)|$($c.arbiterModel)" 'True|agy:gemini-4-hydrogen-high'
    Set-Content -LiteralPath (Join-Path $cfgDir 'phasekit.json') -Value '{ "arbiterModel": "opus high", "gates": [] }'
    $threw = $false
    try { $null = Get-PhaseKitConfig -Path (Join-Path $cfgDir 'phasekit.json') } catch { $threw = $_.Exception.Message -match 'arbiterModel' }
    Test-Case 'a model name with a typo is refused' $threw 'True'

    Write-Host 'the loop, end to end'
    function New-Project([string] $Name, [hashtable] $Settings) {
        $repo = Join-Path $root $Name
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        git -C $repo init -q -b main 2>$null
        git -C $repo config user.email 'test@example.invalid'
        git -C $repo config user.name 'test'
        Set-Content -LiteralPath (Join-Path $repo 'PLAN.md') -Value ("# Plan`n`n## 1. PHASE A - Only`n`n### A.1 - The only task`n`n" +
            "**Problem.** nothing yet`n`n**Done when.** good.txt exists`n`n## 2. Ledger`n`n- [ ] A.1 the only task`n")
        Set-Content -LiteralPath (Join-Path $repo 'PROMPTS.md') -Value "# Prompts`n`n## task`n`nDo {{TASK}}.`n"
        Set-Content -LiteralPath (Join-Path $repo '.gitignore') -Value "logs/`nfake/`nhome/`n"
        Set-Content -LiteralPath (Join-Path $repo 'good.txt') -Value 'good'
        $cfg = [ordered]@{
            plan = 'PLAN.md'; prompts = 'PROMPTS.md'; logDir = 'logs'; model = 'sonnet'; effort = 'medium'
            notify = $false; lessons = $false; handoff = $false
            gates = @(@{ name = 'good'; cwd = '.'; run = 'if (Test-Path good.txt) { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 }' })
            autoSequence = @('A.1')
        }
        foreach ($k in $Settings.Keys) { $cfg[$k] = $Settings[$k] }
        $cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $repo 'phasekit.json')
        git -C $repo add -A 2>$null; git -C $repo commit -q -m 'start' 2>$null
        $fake = Join-Path $repo 'fake'
        New-Item -ItemType Directory -Path $fake -Force | Out-Null
        return [pscustomobject]@{ repo = $repo; fake = $fake }
    }
    function Invoke-Sequence($P, [hashtable] $Env) {
        $saved = @{}
        $vars = @{ PK_FAKE_DIR = $P.fake; PK_REVIEWS = ''; PK_FIX_AT = ''; PK_TAMPER = ''; PK_ASK = ''; PK_ASK_ON_FIX = ''; PK_ARBITER = ''
                   PHASEKIT_HOME = (Join-Path $P.repo 'home'); PHASEKIT_CLAUDE_HOME = (Join-Path $P.repo 'home' 'accounts') }
        foreach ($k in $Env.Keys) { $vars[$k] = $Env[$k] }
        $vars['PATH'] = "$fakeBin$([IO.Path]::PathSeparator)$env:PATH"
        foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
        try { $out = & pwsh -NoProfile -File $phasekit auto -Config (Join-Path $P.repo 'phasekit.json') 2>&1; $code = $LASTEXITCODE }
        finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
        $read = { param($f) if (Test-Path $f) { Get-Content -LiteralPath $f -Raw } else { '' } }
        return [pscustomobject]@{
            code = $code; out = ($out -join "`n")
            calls = @((& $read (Join-Path $P.fake 'calls.txt')) -split "`r?`n" | Where-Object { $_ })
            prompts = (& $read (Join-Path $P.fake 'prompts.txt'))
            merged = [bool] (git -C $P.repo log main --oneline | Select-String 'Merge branch')
            stop = (& $read (Join-Path $P.repo 'logs' 'auto-stopped.txt'))
            decisions = (& $read (Join-Path $P.repo 'logs' 'decisions.md'))
            journal = (& $read (Join-Path $P.repo 'logs' 'auto-progress.log'))
        }
    }

    # 1. Off: a question stops the sequence, as it always did.
    $r = Invoke-Sequence (New-Project 'off' @{}) @{ PK_ASK = '1' }
    Test-Case 'off: the question reaches a person' "$($r.code)|$($r.merged)|$($r.calls -join ';')" '1|False|run sonnet medium'

    # 2. On, a technical question: answered, recorded, carried on, merged.
    $r = Invoke-Sequence (New-Project 'answer' @{ arbiter = $true }) @{ PK_ASK = '1' }
    Test-Case 'answered: the target lands' "$($r.code)|$($r.merged)" '0|True'
    Test-Case 'run, the arbiter (read-only), then the same conversation' ($r.calls -join ';') 'run sonnet medium;arbiter opus high;resume sonnet medium'
    Test-Case 'the arbiter saw the question' ($r.prompts -match '(?s)=== arbiter.*Option \(a\) or option \(b\)\?') 'True'
    Test-Case 'the agent was told who answered' ($r.prompts -match 'Answer to your question, from the arbiter') 'True'
    Test-Case 'decisions.md has the question and the answer' (($r.decisions -match 'Option \(a\) or option \(b\)') -and ($r.decisions -match 'Take option \(a\)')) 'True'
    Test-Case 'the journal says so' ($r.journal -match 'the arbiter answered') 'True'

    # 3. A product choice: escalated, and the owner gets the arbiter's summary.
    $r = Invoke-Sequence (New-Project 'escalate' @{ arbiter = $true }) @{ PK_ASK = '1'; PK_ARBITER = 'ESCALATE' }
    Test-Case 'escalated: the sequence stops' "$($r.code)|$($r.merged)|$($r.calls -join ';')" '1|False|run sonnet medium;arbiter opus high'
    Test-Case 'the stop note carries the arbiter''s view' ($r.stop -match 'the arbiter, for the owner' -and $r.stop -match 'Recommend \(b\)') 'True'
    Test-Case 'nothing is recorded as decided' ([string]::IsNullOrEmpty($r.decisions)) 'True'

    # 4. No decision: the stop is the old one.
    $r = Invoke-Sequence (New-Project 'none' @{ arbiter = $true }) @{ PK_ASK = '1'; PK_ARBITER = 'NONE' }
    Test-Case 'no decision: a person decides' "$($r.code)|$($r.journal -match 'gave no decision')" '1|True'

    # 5. An arbiter that touched the repository: its answer is void.
    $r = Invoke-Sequence (New-Project 'tamper' @{ arbiter = $true }) @{ PK_ASK = '1'; PK_ARBITER = 'TAMPER' }
    Test-Case 'a tampering arbiter is not listened to' "$($r.code)|$($r.calls -join ';')" '1|run sonnet medium;arbiter opus high'
    Test-Case 'and the run says why' ($r.out -match 'decision is void') 'True'

    # 6. A fix round that stops to ask, as M7.2 did: answered, then reviewed again, merged.
    $r = Invoke-Sequence (New-Project 'after-fix' @{ arbiter = $true; review = $true; fixRounds = @('same') }) @{ PK_REVIEWS = 'FAIL,PASS'; PK_ASK_ON_FIX = '1' }
    Test-Case 'a question in a fix round is answered too' "$($r.code)|$($r.merged)" '0|True'
    Test-Case 'review, round, arbiter, answer, review' ($r.calls -join ';') 'run sonnet medium;review opus high;resume sonnet medium;arbiter opus high;resume sonnet medium;review opus high'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails) { Write-Host "$fails failed." -ForegroundColor Red; exit 1 }
Write-Host 'all green.' -ForegroundColor Green
