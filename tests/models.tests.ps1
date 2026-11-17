<#
    Choosing the model: tiers and autoTier, the per-CLI prompt notes, several reviewers,
    limitFallback, and Antigravity's usage in `phasekit spend`. Unit cases first, then
    `phasekit auto` end to end against the fake claude and the fake agy.

        pwsh -NoProfile -File tests/models.tests.ps1
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

$root = Join-Path ([IO.Path]::GetTempPath()) ('phasekit-models-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$phasekit = Join-Path $PSScriptRoot '..' 'bin' 'phasekit.ps1'
$sep = [IO.Path]::PathSeparator
$savedPath = $env:PATH
$env:PATH = (Join-Path $PSScriptRoot 'fake-agy') + $sep + (Join-Path $PSScriptRoot 'fake-claude') + $sep + $env:PATH

$hardSection = "### A.1 - Reconcile the tracker`n`n**Problem.** A race condition between restore and discard breaks an invariant and loses data.`n`n**Done when.** the test passes."
$mechSection = "### A.1 - Refresh the README`n`n**Problem.** The README documentation and the screenshots are out of date.`n`n**Done when.** the README shows the new commands."
$plainSection = "### A.1 - Add a setting`n`n**Problem.** Users want to choose the interval.`n`n**Done when.** the setting is stored and read."

function New-Config([string] $Section, [hashtable] $Settings) {
    $dir = Join-Path $root ([guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'PLAN.md') -Value ("# Plan`n`n## 1. PHASE A - Only`n`n$Section`n`n## 2. Ledger`n`n- [ ] A.1 the task`n")
    Set-Content -LiteralPath (Join-Path $dir 'PROMPTS.md') -Value "## task`n"
    $cfg = [ordered]@{ plan = 'PLAN.md'; prompts = 'PROMPTS.md'; logDir = 'logs'; model = 'opus'; effort = 'medium'; gates = @(); autoSequence = @('A.1') }
    foreach ($k in $Settings.Keys) { $cfg[$k] = $Settings[$k] }
    $cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $dir 'phasekit.json')
    return (Get-PhaseKitConfig -Path (Join-Path $dir 'phasekit.json'))
}
function Get-Pick($c) { $p = Resolve-TargetModel -Config $c -Item @(Get-AutoSequence -Config $c)[0]; return "$($p.model)/$($p.effort)" }

try {
    Write-Host 'reading a task''s tier from the plan'

    Test-Case 'races, invariants, data loss: hard' (Get-TaskTier -Config (New-Config $hardSection @{}) -Target 'A.1').tier 'hard'
    Test-Case 'README and screenshots: mechanical' (Get-TaskTier -Config (New-Config $mechSection @{}) -Target 'A.1').tier 'mechanical'
    Test-Case 'nothing either way: standard' (Get-TaskTier -Config (New-Config $plainSection @{}) -Target 'A.1').tier 'standard'
    $long = "### A.1 - Big`n`n**Problem.** " + ((1..950 | ForEach-Object { 'word' }) -join ' ') + "`n`n**Done when.** x"
    Test-Case 'a very long section is hard' (Get-TaskTier -Config (New-Config $long @{}) -Target 'A.1').tier 'hard'
    Test-Case 'the reason names what it found' ((Get-TaskTier -Config (New-Config $hardSection @{}) -Target 'A.1').why -match 'race') 'True'

    Write-Host 'which model a target gets'

    Test-Case 'nothing set: the configured model' (Get-Pick (New-Config $hardSection @{})) 'opus/medium'
    Test-Case 'autoTier, hard, no tiers: the model at xhigh' (Get-Pick (New-Config $hardSection @{ autoTier = $true })) 'opus/xhigh'
    Test-Case 'autoTier, mechanical, no tiers: sonnet/medium' (Get-Pick (New-Config $mechSection @{ autoTier = $true })) 'sonnet/medium'
    $tiers = @{ mechanical = 'agy:gemini-3.8-flash-medium'; standard = 'sonnet/high'; hard = 'opus/max' }
    Test-Case 'the person''s tiers are used' (Get-Pick (New-Config $mechSection @{ autoTier = $true; tiers = $tiers })) 'agy:gemini-3.8-flash-medium/'
    Test-Case 'a tier named on the entry, without autoTier' (Get-Pick (New-Config $plainSection @{ tiers = $tiers; autoSequence = @(@{ target = 'A.1'; tier = 'hard' }) })) 'opus/max'
    Test-Case 'an entry''s model beats any tier' (Get-Pick (New-Config $hardSection @{ autoTier = $true; tiers = $tiers; autoSequence = @(@{ target = 'A.1'; model = 'haiku' }) })) 'haiku/'
    Test-Case 'an entry''s effort applies on top of its tier' (Get-Pick (New-Config $plainSection @{ tiers = $tiers; autoSequence = @(@{ target = 'A.1'; tier = 'standard'; effort = 'low' }) })) 'sonnet/low'
    $agyHard = Get-TierSpec -Config (New-Config $plainSection @{ model = 'agy:gemini-4-argon-high' }) -Tier 'hard'
    Test-Case 'an agy model gets no effort of its own' "$($agyHard.model)|$($null -eq $agyHard.effort)" 'agy:gemini-4-argon-high|True'
    $threw = $false
    try { $null = New-Config $plainSection @{ tiers = @{ easy = 'sonnet' } } } catch { $threw = $_.Exception.Message -match 'mechanical, standard and hard' }
    Test-Case 'an unknown tier name is refused' $threw 'True'
    $threw = $false
    # Entries are read when the sequence is, not when the config is.
    try { $null = Get-AutoSequence -Config (New-Config $plainSection @{ autoSequence = @(@{ target = 'A.1'; tier = 'medium' }) }) } catch { $threw = $_.Exception.Message -match 'tier' }
    Test-Case 'an unknown tier on an entry is refused' $threw 'True'
    Test-Case 'an agy label has no effort' (Format-ModelLabel -Model 'agy:x-high' -Effort 'high') 'agy:x-high'
    Test-Case 'a Claude label has it' (Format-ModelLabel -Model 'opus' -Effort 'high') 'opus/high'

    Write-Host 'what each CLI is told'

    $c = New-Config $plainSection @{}
    Set-Content -LiteralPath (Join-Path $c.workingDir 'CLAUDE.md') -Value '# rules'
    $n = Get-BackendNote -Config $c -Model 'agy:gemini-x'
    Test-Case 'agy is pointed at CLAUDE.md, which it does not load' ($n -match 'PROJECT INSTRUCTIONS.*CLAUDE\.md') 'True'
    Test-Case 'and given the working discipline' ($n -match 'never guess') 'True'
    $n = Get-BackendNote -Config $c -Model 'opus'
    Test-Case 'Claude is not pointed at its own CLAUDE.md' ($n -match 'PROJECT INSTRUCTIONS') 'False'
    Test-Case 'Claude is told the context is compacted' ($n -match 'compacted automatically') 'True'
    Set-Content -LiteralPath (Join-Path $c.workingDir 'AGENTS.md') -Value '# rules'
    Test-Case 'Claude is pointed at AGENTS.md' ((Get-BackendNote -Config $c -Model 'opus') -match 'AGENTS\.md') 'True'
    # A target with no prompt block falls back to a pointer prompt, which used to drop
    # every note: lessons, handoff, project rules.
    $c.model = 'agy:gemini-x'
    $pointer = Build-PhasePrompt -Config $c -Phase 'A.1' 6>$null
    Test-Case 'the pointer prompt keeps the notes' (($pointer -match 'PROJECT INSTRUCTIONS') -and ($pointer -match 'LESSONS FROM')) 'True'

    Write-Host 'settings'

    $c = New-Config $plainSection @{ reviewModel = @('opus', 'agy:gemini-4-hydrogen-high'); limitFallback = @('agy:claude-opus-5-5-high') }
    Test-Case 'several reviewers are read' ($c.reviewModels -join ',') 'opus,agy:gemini-4-hydrogen-high'
    Test-Case 'the first is reviewModel' $c.reviewModel 'opus'
    Test-Case 'limitFallback is read' ($c.limitFallback -join ',') 'agy:claude-opus-5-5-high'
    $threw = $false
    try { $null = New-Config $plainSection @{ limitFallback = @('opus xhigh') } } catch { $threw = $_.Exception.Message -match 'limitFallback' }
    Test-Case 'a malformed fallback is refused' $threw 'True'

    Write-Host 'Antigravity''s usage in phasekit spend'

    $log = Join-Path $root 'agy-spend.log'
    @(
        '{"event":"step_update","step_update":{"conversation_id":"c","step_index":1,"state":"DONE","step_type":"agent_response","usage":{"input_tokens":1000,"output_tokens":50,"thinking_tokens":10,"cache_read_tokens":9000,"total_tokens":1060}}}'
        '{"event":"step_update","step_update":{"conversation_id":"c","step_index":3,"state":"DONE","step_type":"agent_response","text_delta":"x","usage":{"input_tokens":200,"output_tokens":5,"thinking_tokens":0,"cache_read_tokens":11000,"total_tokens":205}}}'
    ) | Set-Content -LiteralPath $log
    $s = Get-LogSpend -LogPath $log
    Test-Case 'each response is one request' $s.requests 2
    Test-Case 'the context is input plus cached read' $s.peak 11200
    Test-Case 'thinking counts as output' $s.output 65

    Write-Host 'the loop, end to end'

    function New-Project([string] $Name, [hashtable] $Settings, [string] $Section = $plainSection, [switch] $Good) {
        $repo = Join-Path $root $Name
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        git -C $repo init -q -b main 2>$null
        git -C $repo config user.email 'test@example.invalid'; git -C $repo config user.name 'test'
        Set-Content -LiteralPath (Join-Path $repo 'PLAN.md') -Value ("# Plan`n`n## 1. PHASE A - Only`n`n$Section`n`n## 2. Ledger`n`n- [ ] A.1 the only task`n")
        Set-Content -LiteralPath (Join-Path $repo 'PROMPTS.md') -Value "# Prompts`n`n## task`n`nDo {{TASK}}.`n"
        Set-Content -LiteralPath (Join-Path $repo '.gitignore') -Value "logs/`nfake/`nhome/`n"
        Set-Content -LiteralPath (Join-Path $repo 'CLAUDE.md') -Value '# Project rules'
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
        # The accounts are the test's own (none, unless it makes some), never the machine's.
        $vars = @{ PK_FAKE_DIR = $P.fake; PK_REVIEWS = ''; PK_AGY_REVIEWS = ''; PK_FIX_AT = ''; PK_AGY_LIMIT = ''; PK_CLAUDE_LIMIT = ''
                   PK_CLAUDE_LIMIT_ACCOUNTS = ''; PK_CLAUDE_AUTH_ACCOUNTS = ''; PHASEKIT_HOME = (Join-Path $P.repo 'home')
                   PHASEKIT_CLAUDE_HOME = (Join-Path $P.repo 'home' 'accounts'); CLAUDE_CONFIG_DIR = '' }
        foreach ($k in $Env.Keys) { $vars[$k] = $Env[$k] }
        $saved = @{}
        foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
        try { $out = & pwsh -NoProfile -File $phasekit auto -Config (Join-Path $P.repo 'phasekit.json') 2>&1; $code = $LASTEXITCODE }
        finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
        $read = { param($f) $p = Join-Path $P.fake $f; if (Test-Path $p) { Get-Content -LiteralPath $p -Raw } else { '' } }
        $journal = Join-Path $P.repo 'logs' 'auto-progress.log'
        return [pscustomobject]@{
            code = $code; out = ($out -join "`n")
            calls = @((& $read 'calls.txt') -split "`r?`n" | Where-Object { $_ })
            prompts = (& $read 'prompts.txt')
            merged = [bool] (git -C $P.repo log main --oneline | Select-String 'Merge branch')
            journal = $(if (Test-Path $journal) { Get-Content -LiteralPath $journal -Raw } else { '' })
            accounts = @((& $read 'accounts.txt') -split "`r?`n" | Where-Object { $_ })
            limits = $(if (Test-Path (Join-Path $P.repo 'home' 'account-limits.json')) { Get-Content -LiteralPath (Join-Path $P.repo 'home' 'account-limits.json') -Raw } else { '' })
        }
    }
    function Add-Accounts($P) {
        # Two signed-in Claude accounts on the test's "machine": main and b.
        foreach ($n in @('.claude', '.claude-b')) {
            $d = Join-Path $P.repo 'home' 'accounts' $n
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $d '.credentials.json') -Value '{}'
        }
    }

    # 1. autoTier sends a mechanical task to the mechanical tier's model, and says why.
    $p = New-Project 'tier' @{ autoTier = $true; tiers = @{ mechanical = 'agy:gemini-flash-fake' } } -Section $mechSection -Good
    $r = Invoke-Sequence $p @{}
    Test-Case 'a mechanical task runs on the mechanical tier' "$($r.code)|$($r.merged)|$($r.calls -join ';')" '0|True|agy-run gemini-flash-fake '
    Test-Case 'the journal says which model and why' ($r.journal -match 'agy:gemini-flash-fake \(mechanical \(auto: mentions') 'True'
    Test-Case 'agy was pointed at CLAUDE.md' ($r.prompts -match 'PROJECT INSTRUCTIONS') 'True'

    # 2. Claude's allowance is spent: the target goes on, on the fallback, and lands.
    $p = New-Project 'fallback' @{ limitFallback = @('agy:claude-opus-fake') } -Good
    $r = Invoke-Sequence $p @{ PK_CLAUDE_LIMIT = '1' }
    Test-Case 'a spent allowance hands over instead of waiting' "$($r.code)|$($r.merged)" '0|True'
    Test-Case 'claude first, then the fallback, fresh' ($r.calls -join ';') 'run sonnet medium;agy-fresh claude-opus-fake '
    Test-Case 'the new session is told why it takes over' ($r.prompts -match 'allowance ran out') 'True'
    Test-Case 'the journal says so' ($r.journal -match 'handing over to agy:claude-opus-fake') 'True'

    # 2b. switchAccounts: the other Claude account first, in the same conversation.
    $p = New-Project 'switch' @{ switchAccounts = $true; limitFallback = @('agy:claude-opus-fake') } -Good
    Add-Accounts $p
    $r = Invoke-Sequence $p @{ PK_CLAUDE_LIMIT_ACCOUNTS = '.claude' }
    Test-Case 'a spent account hands over to the other one' "$($r.code)|$($r.merged)" '0|True'
    Test-Case 'same model, same conversation, no fallback' ($r.calls -join ';') 'run sonnet medium;resume sonnet medium'
    Test-Case 'main first, then b' ($r.accounts -join ',') '.claude,.claude-b'
    Test-Case 'the spent account is written down' ($r.limits -match '"main"') 'True'
    Test-Case 'and the run says why' ($r.out -match 'Carrying on now under account b') 'True'
    $logText = (Get-ChildItem -Path (Join-Path $p.repo 'logs') -Filter 'phase-*.log' | Get-Content -Raw) -join "`n"
    Test-Case 'each attempt names its account in the log' (($logText -match '\[phasekit\] account main') -and ($logText -match '\[phasekit\] account b')) 'True'

    # 2c. Every account spent: then, and only then, limitFallback.
    $p = New-Project 'switch-all' @{ switchAccounts = $true; limitFallback = @('agy:claude-opus-fake') } -Good
    Add-Accounts $p
    $r = Invoke-Sequence $p @{ PK_CLAUDE_LIMIT_ACCOUNTS = '.claude,.claude-b' }
    Test-Case 'all accounts spent: on to the fallback' "$($r.code)|$($r.merged)" '0|True'
    Test-Case 'each account once, then agy' ($r.calls -join ';') 'run sonnet medium;resume sonnet medium;agy-fresh claude-opus-fake '
    Test-Case 'both are written down' (($r.limits -match '"main"') -and ($r.limits -match '"b"')) 'True'

    # 2d. switchAccounts off: two accounts, but straight to the fallback, as before.
    $p = New-Project 'no-switch' @{ limitFallback = @('agy:claude-opus-fake') } -Good
    Add-Accounts $p
    $r = Invoke-Sequence $p @{ PK_CLAUDE_LIMIT_ACCOUNTS = '.claude' }
    Test-Case 'without switchAccounts the accounts are left alone' ($r.calls -join ';') 'run sonnet medium;agy-fresh claude-opus-fake '

    # 2e. What happened on 2026-11-16: one account spent, the other's login expired. The
    #     expired login is said as such, written down, and the fallback carries on.
    $p = New-Project 'expired-login' @{ switchAccounts = $true; limitFallback = @('agy:claude-opus-fake') } -Good
    Add-Accounts $p
    $r = Invoke-Sequence $p @{ PK_CLAUDE_LIMIT_ACCOUNTS = '.claude'; PK_CLAUDE_AUTH_ACCOUNTS = '.claude-b' }
    Test-Case 'a spent account, then an expired login: the fallback' "$($r.code)|$($r.merged)" '0|True'
    Test-Case 'one try per account, then agy' ($r.calls -join ';') 'run sonnet medium;resume sonnet medium;agy-fresh claude-opus-fake '
    Test-Case 'the expired login is named, not called a limit' ($r.out -match 'login has expired') 'True'
    Test-Case 'and kept away from the next switch' ($r.limits -match '"b"') 'True'

    # 2f. An expired login with nowhere to go stops at once, saying how to log in - no
    #     retries, no wait for a reset that would not help.
    $p = New-Project 'login-only' @{} -Good
    Add-Accounts $p
    $r = Invoke-Sequence $p @{ PK_CLAUDE_AUTH_ACCOUNTS = '.claude' }
    Test-Case 'an expired login alone stops the run' ($r.calls -join ';') 'run sonnet medium'
    Test-Case 'and says how to log in' ($r.out -match '/login') 'True'

    # 3. Two reviewers of different families: one passes, one rejects - rejected; fixed;
    #    both pass - merged.
    $p = New-Project 'two-reviewers' @{ review = $true; reviewModel = @('opus', 'agy:gemini-fake'); fixRounds = @('same') } -Good
    $r = Invoke-Sequence $p @{ PK_REVIEWS = 'PASS,PASS'; PK_AGY_REVIEWS = 'FAIL,PASS' }
    Test-Case 'one rejection is enough to send it back' "$($r.code)|$($r.merged)" '0|True'
    Test-Case 'both reviewed, twice, around the fix' ($r.calls -join ';') 'run sonnet medium;review opus high;agy-review gemini-fake plan;resume sonnet medium;review opus high;agy-review gemini-fake plan'
    Test-Case 'the builder was told which reviewer said what' ($r.prompts -match '\[reviewer agy:gemini-fake\]') 'True'
}
finally {
    $env:PATH = $savedPath
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails -gt 0) { Write-Host "$fails failing" -ForegroundColor Red; exit 1 }
Write-Host 'all green.' -ForegroundColor Green
