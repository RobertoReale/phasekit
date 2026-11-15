<#
    The independent reviewer and the fix rounds. The pure parts first (settings, verdicts,
    prompts), then `phasekit auto` driven end to end against a fake claude
    (tests/fake-claude/claude.ps1), so the loop that decides between merging, another
    round and a stop is tested as it runs, without spending anything.

        pwsh -NoProfile -File tests/review.tests.ps1
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

$root = Join-Path ([IO.Path]::GetTempPath()) ('phasekit-review-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$phasekit = Join-Path $PSScriptRoot '..' 'bin' 'phasekit.ps1'
$fakeBin = Join-Path $PSScriptRoot 'fake-claude'

try {
    Write-Host 'the settings'

    $cfgFile = Join-Path $root 'phasekit.json'
    Set-Content -LiteralPath $cfgFile -Value '{ "gates": [] }'
    $c = Get-PhaseKitConfig -Path $cfgFile
    Test-Case 'review is off by default' $c.review 'False'
    Test-Case 'and no fix rounds: a rejection stops, as before' @($c.fixRounds).Count 0
    Test-Case 'the reviewer defaults to opus/high' "$($c.reviewModel)/$($c.reviewEffort)" 'opus/high'
    Set-Content -LiteralPath $cfgFile -Value '{ "gates": [], "review": true, "reviewModel": "sonnet", "fixRounds": ["same", "opus/xhigh", "opus"] }'
    $c = Get-PhaseKitConfig -Path $cfgFile
    $r = @(Get-FixRounds -Config $c)
    Test-Case 'three rounds are read' $r.Count 3
    Test-Case '"same" keeps the target''s model' "$($null -eq $r[0].model)" 'True'
    Test-Case 'a model and an effort' "$($r[1].model)/$($r[1].effort)" 'opus/xhigh'
    Test-Case 'a model alone' "$($r[2].model)/$($null -eq $r[2].effort)" 'opus/True'
    Set-Content -LiteralPath $cfgFile -Value '{ "gates": [], "fixRounds": ["opus xhigh"] }'
    $threw = $false
    try { $null = Get-PhaseKitConfig -Path $cfgFile } catch { $threw = $_.Exception.Message -match 'fixRounds' }
    Test-Case 'a malformed round is refused at load, not hours later' $threw 'True'

    Set-Content -LiteralPath $cfgFile -Value '{ "gates": [], "review": true, "autoSequence": [ "A.1", { "target": "A.2", "review": false }, { "target": "A.3" } ] }'
    $c = Get-PhaseKitConfig -Path $cfgFile
    $seq = @(Get-AutoSequence -Config $c)
    Test-Case 'a bare target follows the global switch' (Test-ReviewWanted -Config $c -Item $seq[0]) 'True'
    Test-Case 'an entry can turn it off for itself' (Test-ReviewWanted -Config $c -Item $seq[1]) 'False'
    Test-Case 'an entry that says nothing follows the global' (Test-ReviewWanted -Config $c -Item $seq[2]) 'True'
    $c.review = $false
    $one = [pscustomobject]@{ review = $true }
    Test-Case 'and one can turn it on with the global off' (Test-ReviewWanted -Config $c -Item $one) 'True'

    Write-Host 'reading a verdict'

    Test-Case 'PASS' (ConvertFrom-ReviewVerdict -Text "ok`nVERDICT: PASS").verdict 'PASS'
    $f = ConvertFrom-ReviewVerdict -Text "Read it.`n**VERDICT: FAIL**`n1. a.ts:3 - wrong - test"
    Test-Case 'FAIL, in bold' $f.verdict 'FAIL'
    Test-Case 'with its findings' $f.findings '1. a.ts:3 - wrong - test'
    Test-Case 'no verdict is inconclusive, never a pass' (ConvertFrom-ReviewVerdict -Text 'Looks fine to me.').verdict 'INCONCLUSIVE'
    Test-Case 'only the last verdict counts' (ConvertFrom-ReviewVerdict -Text "Format: VERDICT: PASS`nVERDICT: FAIL`n1. x").verdict 'FAIL'
    Test-Case 'a PASS carries no findings' (ConvertFrom-ReviewVerdict -Text "VERDICT: PASS`nnits").findings ''

    Write-Host 'what each side is told'

    $pc = [pscustomobject]@{ plan = (Join-Path $root 'nope.md'); codeDir = $root; gates = @([pscustomobject]@{ name = 'unit' }) }
    $p = Get-ReviewPrompt -Config $pc -Target 'A.1' -Base 'abc' -Branch 'plan/phase-A.1'
    Test-Case 'the reviewer gets the diff to read' ($p -match 'git diff abc\.\.plan/phase-A\.1') 'True'
    Test-Case 'is told it cannot change anything' ($p -match 'cannot change anything') 'True'
    Test-Case 'and that an invented finding is a cost' ($p -match 'invented') 'True'
    Test-Case 'a first review has no previous round' ($p -match 'previous review') 'False'
    $p2 = Get-ReviewPrompt -Config $pc -Target 'A.1' -Base 'abc' -Branch 'b' -Previous ([pscustomobject]@{ findings = 'F1'; answer = 'A1' })
    Test-Case 'a second review sees the findings and the answer' (($p2 -match 'F1') -and ($p2 -match 'A1')) 'True'
    $m = Get-RejectionMessage -Target 'A.1' -Kind 'review' -Detail '1. x' -Round '1 of 2'
    Test-Case 'the builder may refute a finding with evidence' ($m -match 'do not change the code for') 'True'
    Test-Case 'and may never weaken a test' ($m -match 'Never weaken') 'True'
    Test-Case 'a gate rejection says reproduce first' ((Get-RejectionMessage -Target 'A.1' -Kind 'gates' -Detail 'x') -match 'Reproduce') 'True'

    Write-Host 'the loop, end to end against a fake claude'

    function New-Project([string] $Name, [hashtable] $Settings, [switch] $Good) {
        $repo = Join-Path $root $Name
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        git -C $repo init -q -b main 2>$null
        git -C $repo config user.email 'test@example.invalid'
        git -C $repo config user.name 'test'
        # A plan that passes `phasekit lint`, which `auto` now runs before anything else.
        Set-Content -LiteralPath (Join-Path $repo 'PLAN.md') -Value ("# Plan`n`n## 1. PHASE A - Only`n`n### A.1 - The only task`n`n" +
            "**Problem.** nothing yet`n`n**Done when.** good.txt exists`n`n## 2. Ledger`n`n- [ ] A.1 the only task`n")
        Set-Content -LiteralPath (Join-Path $repo 'PROMPTS.md') -Value "# Prompts`n`n## task`n`nDo {{TASK}}.`n"
        # The fake's notes and the isolated phasekit home live in the repo for tidiness, and
        # must not make the tree dirty: phasekit would rightly refuse to merge it.
        Set-Content -LiteralPath (Join-Path $repo '.gitignore') -Value "logs/`nfake/`nhome/`n"
        if ($Good) { Set-Content -LiteralPath (Join-Path $repo 'good.txt') -Value 'good' }
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
        $vars = @{ PK_FAKE_DIR = $P.fake; PK_REVIEWS = ''; PK_FIX_AT = ''; PK_TAMPER = ''; PHASEKIT_HOME = (Join-Path $P.repo 'home') }
        foreach ($k in $Env.Keys) { $vars[$k] = $Env[$k] }
        $vars['PATH'] = "$fakeBin$([IO.Path]::PathSeparator)$env:PATH"
        foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
        try {
            $out = & pwsh -NoProfile -File $phasekit auto -Config (Join-Path $P.repo 'phasekit.json') 2>&1
            $code = $LASTEXITCODE
        }
        finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
        $calls = if (Test-Path (Join-Path $P.fake 'calls.txt')) { @(Get-Content -LiteralPath (Join-Path $P.fake 'calls.txt')) } else { @() }
        $merged = [bool] (git -C $P.repo log main --oneline | Select-String 'Merge branch')
        $stop = Join-Path $P.repo 'logs' 'auto-stopped.txt'
        return [pscustomobject]@{
            code = $code; calls = $calls; merged = $merged; out = ($out -join "`n")
            stop = $(if (Test-Path $stop) { Get-Content -LiteralPath $stop -Raw } else { '' })
            prompts = $(if (Test-Path (Join-Path $P.fake 'prompts.txt')) { Get-Content -LiteralPath (Join-Path $P.fake 'prompts.txt') -Raw } else { '' })
        }
    }

    # 1. Both off: exactly the old path.
    $p = New-Project 'plain' @{} -Good
    $r = Invoke-Sequence $p @{}
    Test-Case 'off: one run, merged' "$($r.calls -join ';')|$($r.merged)" 'run sonnet medium|True'

    # 2. Gates red, nothing configured: the old stop.
    $p = New-Project 'gates-stop' @{}
    $r = Invoke-Sequence $p @{}
    Test-Case 'no rounds: a red gate stops the sequence' "$($r.code)|$($r.merged)" '1|False'
    Test-Case 'with the old stop note' ($r.stop -match 'gate\(s\) failing') 'True'

    # 3. Gates red, two rounds; the first fails, the second (stronger) fixes it.
    $p = New-Project 'escalate' @{ fixRounds = @('same', 'opus/xhigh') }
    $r = Invoke-Sequence $p @{ PK_FIX_AT = '2' }
    Test-Case 'escalation: merged after the second round' "$($r.code)|$($r.merged)" '0|True'
    Test-Case 'the first round ran on the target''s own model' $r.calls[1] 'resume sonnet medium'
    Test-Case 'the second on the stronger one' $r.calls[2] 'resume opus xhigh'
    Test-Case 'and was told what failed' ($r.prompts -match 'phasekit ran the gates on your branch') 'True'

    # 4. Rounds run out: the stop says so.
    $p = New-Project 'exhausted' @{ fixRounds = @('same') }
    $r = Invoke-Sequence $p @{ PK_FIX_AT = '9' }
    Test-Case 'rounds exhausted: stopped, not merged' "$($r.code)|$($r.merged)" '1|False'
    Test-Case 'the stop note counts the rounds' ($r.stop -match 'after 1 fix round') 'True'

    # 5. Review FAIL, one round, then PASS on the second look.
    $p = New-Project 'review-fix' @{ review = $true; reviewModel = 'opus'; reviewEffort = 'high'; fixRounds = @('same') } -Good
    $r = Invoke-Sequence $p @{ PK_REVIEWS = 'FAIL,PASS' }
    Test-Case 'review: fail, fix, pass, merged' "$($r.code)|$($r.merged)" '0|True'
    Test-Case 'in that order' ($r.calls -join ';') 'run sonnet medium;review opus high;resume sonnet medium;review opus high'
    Test-Case 'the builder was given the findings' ($r.prompts -match 'An independent reviewer read your work') 'True'
    Test-Case 'the second review saw the builder''s answer' ($r.prompts -match 'Finding 1 was real') 'True'
    Test-Case 'the review logs are kept apart from the target''s' @(Get-ChildItem (Join-Path $p.repo 'logs') -Filter 'review-A.1-*.log').Count 2

    # 6. Review FAIL with no rounds: a person is asked.
    $p = New-Project 'review-stop' @{ review = $true } -Good
    $r = Invoke-Sequence $p @{ PK_REVIEWS = 'FAIL' }
    Test-Case 'review FAIL, no rounds: stopped' "$($r.code)|$($r.merged)" '1|False'
    Test-Case 'the stop note carries the findings' ($r.stop -match 'work\.txt:1 - the work is wrong') 'True'

    # 7. No verdict: the gates decide alone, and it is said.
    $p = New-Project 'review-none' @{ review = $true } -Good
    $r = Invoke-Sequence $p @{ PK_REVIEWS = 'NONE' }
    Test-Case 'an inconclusive review leaves it to the gates' "$($r.code)|$($r.merged)" '0|True'
    Test-Case 'and says so' ($r.out -match 'the gates decide alone') 'True'

    # 8. A reviewer that changed the repository: nothing is trusted, nothing merged.
    $p = New-Project 'review-tamper' @{ review = $true } -Good
    $r = Invoke-Sequence $p @{ PK_REVIEWS = 'PASS'; PK_TAMPER = '1' }
    Test-Case 'a reviewer that wrote a file stops the sequence' "$($r.code)|$($r.merged)" '1|False'
    Test-Case 'and the stop says why' ($r.stop -match 'changed while the read-only reviewer ran') 'True'

    # 9. A target that opts out is not reviewed.
    $p = New-Project 'review-optout' @{ review = $true; autoSequence = @(@{ target = 'A.1'; review = $false }) } -Good
    $r = Invoke-Sequence $p @{ PK_REVIEWS = 'FAIL' }
    Test-Case 'an entry with review false is merged unreviewed' "$($r.calls -join ';')|$($r.merged)" 'run sonnet medium|True'

    # The reviewer is read-only by construction: the tools it is handed.
    Test-Case 'the reviewer gets no editing tool' ((Get-Content -LiteralPath $phasekit -Raw) -match "'--disallowedTools', 'Edit', 'Write'") 'True'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails -gt 0) { Write-Host "$fails failing" -ForegroundColor Red; exit 1 }
Write-Host 'all green.' -ForegroundColor Green
