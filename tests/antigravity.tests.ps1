<#
    Antigravity models ("agy:<slug>"): the argument translation, reading agy's stream,
    its last words and its quota errors, and `phasekit auto` end to end against a fake
    agy (tests/fake-agy) beside the fake claude: a target on Antigravity, an Antigravity
    reviewer in plan mode, and a fix round that changes CLI.

        pwsh -NoProfile -File tests/antigravity.tests.ps1
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

$root = Join-Path ([IO.Path]::GetTempPath()) ('phasekit-agy-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$phasekit = Join-Path $PSScriptRoot '..' 'bin' 'phasekit.ps1'
$sep = [IO.Path]::PathSeparator
$savedPath = $env:PATH
$env:PATH = (Join-Path $PSScriptRoot 'fake-agy') + $sep + (Join-Path $PSScriptRoot 'fake-claude') + $sep + $env:PATH

try {
    Write-Host 'which CLI, and what it is told'

    Test-Case 'agy:<slug> is Antigravity' (Get-AgentBackend 'agy:gemini-4-argon-high') 'agy'
    Test-Case 'anything else is Claude' (Get-AgentBackend 'opus') 'claude'
    Test-Case 'the fake agy is found on PATH' ([bool] (Get-AgyExecutable)) 'True'

    $c = ConvertTo-AgentCommand -ClaudeArgs @('-p', 'do it', '--permission-mode', 'bypassPermissions', '--model', 'agy:gemini-4-argon-high', '--effort', 'high', '--output-format', 'stream-json', '--verbose', '--autocompact', '150000', '--strict-mcp-config')
    Test-Case 'a run goes to agy' $c.backend 'agy'
    Test-Case 'with the slug, without the prefix' ($c.args -join ' ' -match '--model gemini-4-argon-high') 'True'
    Test-Case 'claude-only flags are dropped' (($c.args -join ' ') -match 'permission-mode|--effort|--verbose|autocompact|strict-mcp') 'False'
    Test-Case 'tools are approved for a working run' ($c.args -contains '--dangerously-skip-permissions') 'True'
    Test-Case 'paid credits are off unless allowed' (($c.args -join ' ') -match '"useG1Credits":false') 'True'
    $c = ConvertTo-AgentCommand -ClaudeArgs @('-p', 'x', '--model', 'agy:m') -AllowCredits $true
    Test-Case 'and on when allowed' (($c.args -join ' ') -match '"useG1Credits":true') 'True'

    $c = ConvertTo-AgentCommand -ClaudeArgs @('--resume', 'agy:abc', '-p', 'go on', '--model', 'opus')
    Test-Case 'resuming an agy conversation goes to agy' $c.backend 'agy'
    Test-Case 'as --conversation, without the prefix' (($c.args -join ' ') -match '--conversation abc\b') 'True'
    Test-Case 'a Claude alias is not passed to agy' (($c.args -join ' ') -match 'opus') 'False'

    $c = ConvertTo-AgentCommand -ClaudeArgs @('-p', 'review', '--model', 'agy:m', '--allowedTools', 'Read', 'Bash(git diff:*)', '--disallowedTools', 'Edit', 'Write')
    Test-Case 'the reviewer runs in plan mode' (($c.args -join ' ') -match '--mode plan') 'True'
    Test-Case 'with no blanket approval' ($c.args -contains '--dangerously-skip-permissions') 'False'
    Test-Case 'and only read-only git commands allowed' (($c.args -join ' ') -match 'git \(diff\|log\|show\|status\|blame\)') 'True'
    Test-Case 'claude''s tool lists are not passed on' (($c.args -join ' ') -match 'allowedTools|Bash\(git') 'False'

    $c = ConvertTo-AgentCommand -ClaudeArgs @('-p', 'x', '--model', 'sonnet')
    Test-Case 'a Claude model is left untouched' "$($c.backend)/$($c.exe)/$($c.args -join ' ')" 'claude/claude/-p x --model sonnet'

    Write-Host 'reading what agy says'

    $log = Join-Path $root 'agy.log'
    @(
        '{"event":"init","conversation_id":"c-1","init":{"model":"gemini-x","cwd":"."}}'
        '{"event":"step_update","step_update":{"conversation_id":"c-1","step_index":1,"state":"DONE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"git status"},"output":"clean"}}}'
        '{"event":"step_update","step_update":{"conversation_id":"c-1","step_index":2,"state":"DONE","step_type":"agent_response","text_delta":"All done."}}'
        '{"event":"result","result":{"conversation_id":"c-1","status":"SUCCESS","response":"All done.\n\nLESSONS\nNONE","num_turns":1}}'
    ) | Set-Content -LiteralPath $log
    $tail = (Get-Content -LiteralPath $log) -join "`n"
    Test-Case 'the last words are the response' (Get-AgentLastWords -LogTail $tail) 'All done.'
    Test-Case 'the collector sees the LESSONS block' ((Get-AgentLastWords -LogTail $tail -KeepLessons) -match 'LESSONS') 'True'

    $sf = Join-Path $root 'pin.session'
    $script:SessionId = $null
    $shown = ((Get-Content -LiteralPath $log | ForEach-Object { Write-StreamLine -Line $_ -SessionFile $sf 6>&1 }) | ForEach-Object { "$_" }) -join "`n"
    Test-Case 'the conversation is pinned with its CLI' (Get-Content -LiteralPath $sf) 'agy:c-1'
    Test-Case 'a tool line is shown' ($shown -match '-> run_command git status') 'True'
    Test-Case 'and the ending' ($shown -match 'DONE  turns=1') 'True'

    $quota = @(
        '{"event":"result","result":{"conversation_id":"c-2","status":"ERROR","response":"","error":"RESOURCE_EXHAUSTED: weekly quota reached"}}'
        'error: RESOURCE_EXHAUSTED: weekly quota reached'
    ) -join "`n"
    Test-Case 'a spent quota is a usage limit' (Get-StopReason -LogTail $quota) 'limit'
    $badModel = '{"event":"result","result":{"conversation_id":"","status":"ERROR","response":"","error":"invalid model selection"}}'
    Test-Case 'an unknown model is not a limit' (Get-StopReason -LogTail $badModel) 'stop'
    $prose = '{"event":"step_update","step_update":{"conversation_id":"c","state":"DONE","step_type":"agent_response","text_delta":"the quota module is exhausted of ideas"}}'
    Test-Case 'the agent''s own words never make a limit' (Get-StopReason -LogTail $prose) 'stop'

    Write-Host 'the loop, end to end'

    function New-Project([string] $Name, [hashtable] $Settings, [switch] $Good) {
        $repo = Join-Path $root $Name
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        git -C $repo init -q -b main 2>$null
        git -C $repo config user.email 'test@example.invalid'; git -C $repo config user.name 'test'
        Set-Content -LiteralPath (Join-Path $repo 'PLAN.md') -Value ("# Plan`n`n## 1. PHASE A - Only`n`n### A.1 - The only task`n`n" +
            "**Problem.** nothing yet`n`n**Done when.** good.txt exists`n`n## 2. Ledger`n`n- [ ] A.1 the only task`n")
        Set-Content -LiteralPath (Join-Path $repo 'PROMPTS.md') -Value "# Prompts`n`n## task`n`nDo {{TASK}}.`n"
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
        $vars = @{ PK_FAKE_DIR = $P.fake; PK_REVIEWS = ''; PK_FIX_AT = ''; PK_AGY_LIMIT = ''; PHASEKIT_HOME = (Join-Path $P.repo 'home') }
        foreach ($k in $Env.Keys) { $vars[$k] = $Env[$k] }
        $saved = @{}
        foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
        try { $out = & pwsh -NoProfile -File $phasekit auto -Config (Join-Path $P.repo 'phasekit.json') 2>&1; $code = $LASTEXITCODE }
        finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
        $read = { param($f) $p = Join-Path $P.fake $f; if (Test-Path $p) { Get-Content -LiteralPath $p -Raw } else { '' } }
        return [pscustomobject]@{
            code = $code; out = ($out -join "`n")
            calls = @((& $read 'calls.txt') -split "`r?`n" | Where-Object { $_ })
            prompts = (& $read 'prompts.txt'); settings = (& $read 'settings.txt')
            merged = [bool] (git -C $P.repo log main --oneline | Select-String 'Merge branch')
        }
    }

    # 1. A target on Antigravity: run, gates, merge.
    $p = New-Project 'agy-target' @{ model = 'agy:gemini-fake' } -Good
    $r = Invoke-Sequence $p @{}
    Test-Case 'a target on agy runs and merges' "$($r.code)|$($r.merged)|$($r.calls -join ';')" '0|True|agy-run gemini-fake '
    Test-Case 'and never spends paid credits' ($r.settings -match '"useG1Credits":false') 'True'
    Test-Case 'its conversation is pinned as agy' ((Get-Content -LiteralPath (Join-Path $p.repo 'logs' 'phase-A.1.session')) -match '^agy:') 'True'

    # 2. A Claude target reviewed by Antigravity: fail, fix in the target's own Claude
    #    conversation, pass.
    $p = New-Project 'agy-review' @{ review = $true; reviewModel = 'agy:gemini-fake'; fixRounds = @('same') } -Good
    $r = Invoke-Sequence $p @{ PK_REVIEWS = 'FAIL,PASS' }
    Test-Case 'a Gemini reviewer, a Claude builder: merged' "$($r.code)|$($r.merged)" '0|True'
    Test-Case 'in that order' ($r.calls -join ';') 'run sonnet medium;agy-review gemini-fake plan;resume sonnet medium;agy-review gemini-fake plan'
    Test-Case 'the agy reviewer is given the diff' ($r.prompts -match '--- diff ---') 'True'

    # 3. A Claude target fails its gates; the fix round is on Antigravity, which cannot
    #    resume a Claude conversation, so it starts fresh, told what failed.
    $p = New-Project 'agy-round' @{ fixRounds = @('agy:gemini-fake') }
    $r = Invoke-Sequence $p @{}
    Test-Case 'a fix round that changes CLI: merged' "$($r.code)|$($r.merged)" '0|True'
    Test-Case 'it ran fresh on agy' ($r.calls -join ';') 'run sonnet medium;agy-fresh gemini-fake '
    Test-Case 'told that the gates failed' ($r.prompts -match 'phasekit ran the gates on your branch') 'True'

    # 4. An agy model with no agy installed is caught by the plan check, before anything.
    $p = New-Project 'agy-missing' @{ model = 'agy:gemini-fake' } -Good
    $env:PATH = (Join-Path $PSScriptRoot 'fake-claude') + $sep + $savedPath
    $hasReal = [bool] (Get-AgyExecutable)
    if (-not $hasReal) {
        $r = Invoke-Sequence $p @{}
        Test-Case 'no agy installed: the plan check stops it' "$($r.code)|$([bool]($r.out -match 'Antigravity CLI'))" '1|True'
    }
    else { Write-Host '  (skipped: a real agy is installed here, so "missing" cannot be staged)' -ForegroundColor DarkGray }
}
finally {
    $env:PATH = $savedPath
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails -gt 0) { Write-Host "$fails failing" -ForegroundColor Red; exit 1 }
Write-Host 'all green.' -ForegroundColor Green
