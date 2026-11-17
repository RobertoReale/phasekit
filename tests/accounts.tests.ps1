<#
    Switching account when an allowance runs out: which directories count as accounts,
    which one the next claude runs under, and whether a conversation survives the move.

        pwsh -NoProfile -File tests/accounts.tests.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'lib' 'PhaseKit.ps1')

$fails = 0
function Test-Case($name, $got, $expected) {
    $ok = ([string] $got) -eq ([string] $expected)
    if (-not $ok) { $script:fails++ }
    $mark = if ($ok) { 'ok  ' } else { 'FAIL' }
    $colour = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  {0}  {1,-56} {2}" -f $mark, $name, $(if ($ok) { '' } else { "got '$got', expected '$expected'" })) -ForegroundColor $colour
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("phasekit-accounts-" + [guid]::NewGuid().ToString('N'))
$fakeHome = Join-Path $root 'home'
$savedHome = $env:PHASEKIT_HOME
$savedConfig = $env:CLAUDE_CONFIG_DIR

try {
    $env:PHASEKIT_HOME = Join-Path $root 'state'
    $main = Join-Path $fakeHome '.claude'
    $b = Join-Path $fakeHome '.claude-b'
    New-Item -ItemType Directory -Force -Path $main, (Join-Path $b 'projects') | Out-Null
    Set-Content -LiteralPath (Join-Path $main '.credentials.json') -Value '{}'
    # Not accounts: an empty .claude-x, a .claudeish directory, and the .claude.json file.
    New-Item -ItemType Directory -Force -Path (Join-Path $fakeHome '.claude-x'), (Join-Path $fakeHome '.claudeish') | Out-Null
    Set-Content -LiteralPath (Join-Path $fakeHome '.claude.json') -Value '{}'

    Write-Host 'finding the accounts'
    $accounts = @(Get-ClaudeAccounts -HomeDir $fakeHome)
    Test-Case 'a login or a projects dir makes an account, nothing else' (($accounts.name) -join ',') 'main,b'
    Test-Case '.claude-b is called b' ($accounts | Where-Object name -eq 'b').dir $b

    Write-Host 'which one the next claude runs under'
    $env:CLAUDE_CONFIG_DIR = $b
    $active = Get-ActiveAccount -HomeDir $fakeHome
    Test-Case 'nothing chosen: the environment decides' $active.name 'b'
    Test-Case 'and it is not imposed on the child' $active.chosen $false

    $picked = Set-ActiveAccount -Name 'main' -HomeDir $fakeHome
    Test-Case 'switching by name' $picked.name 'main'
    $active = Get-ActiveAccount -HomeDir $fakeHome
    Test-Case 'the choice beats the environment' $active.dir $main
    Test-Case 'a chosen account is imposed on the child' $active.chosen $true

    Test-Case 'next goes round' (Set-ActiveAccount -Name 'next' -HomeDir $fakeHome).name 'b'
    Test-Case 'and round again' (Set-ActiveAccount -Name 'next' -HomeDir $fakeHome).name 'main'

    $threw = $false
    try { Set-ActiveAccount -Name 'nope' -HomeDir $fakeHome | Out-Null } catch { $threw = $true }
    Test-Case 'an unknown name is refused' $threw $true
    Test-Case 'and the choice is left alone' (Get-ChosenAccountName) 'main'

    Remove-Item -LiteralPath (Get-AccountStateFile) -Force
    $env:CLAUDE_CONFIG_DIR = $null
    Test-Case 'no choice, no variable: ~/.claude, as claude itself' (Get-ActiveAccount -HomeDir $fakeHome).name 'main'

    Write-Host 'a conversation survives the move'
    $id = '11111111-2222-3333-4444-555555555555'
    $project = Join-Path $b 'projects' 'C--work-repo'
    New-Item -ItemType Directory -Force -Path (Join-Path $project $id 'subagents') | Out-Null
    Set-Content -LiteralPath (Join-Path $project "$id.jsonl") -Value '{"type":"user"}'
    Set-Content -LiteralPath (Join-Path $project $id 'subagents' 'a.jsonl') -Value '{}'

    Test-Case 'the transcript is copied across' (Copy-SessionToAccount -SessionId $id -ToDir $main -Accounts $accounts) $true
    Test-Case 'into a project folder of the same name' (Test-Path (Join-Path $main 'projects' 'C--work-repo' "$id.jsonl")) $true
    Test-Case 'with what sits beside it' (Test-Path (Join-Path $main 'projects' 'C--work-repo' $id 'subagents' 'a.jsonl')) $true
    Test-Case 'a second copy is a no-op' (Copy-SessionToAccount -SessionId $id -ToDir $main -Accounts $accounts) $true
    Test-Case 'an unknown conversation is reported, not invented' `
        (Copy-SessionToAccount -SessionId 'missing' -ToDir $main -Accounts $accounts) $false

    Write-Host 'a switch ends a wait'
    Set-ActiveAccount -Name 'b' -HomeDir $fakeHome | Out-Null
    $log = Join-Path $root 'wait.log'
    $started = Get-Date
    Wait-UntilDeadline -Deadline (Get-Date).AddMinutes(30) -LogPath $log -Account 'main'
    Test-Case 'a wait for another account returns at once' (((Get-Date) - $started).TotalSeconds -lt 5) $true
    Test-Case 'and says why, in the log' ((Get-Content -LiteralPath $log -Raw) -match 'switched to b') $true
    Test-Case 'the note is phasekit''s own, never read as a limit' `
        ((Get-Content -LiteralPath $log -TotalCount 1).StartsWith($script:NoteMarker)) $true

    $started = Get-Date
    Wait-UntilDeadline -Deadline (Get-Date).AddSeconds(2) -Account 'b'
    Test-Case 'the same account waits the deadline out' (((Get-Date) - $started).TotalSeconds -ge 1.5) $true

    Write-Host 'which account is free'
    Test-Case 'nothing known spent: the next one' (Select-FreeAccount -Exclude 'main' -HomeDir $fakeHome).name 'b'
    Test-Case 'and round from the last' (Select-FreeAccount -Exclude 'b' -HomeDir $fakeHome).name 'main'
    $until = (Get-Date).AddMinutes(90)
    Set-AccountLimited -Name 'b' -Until $until
    $read = Read-AccountLimits
    Test-Case 'a spent account is written down' ([Math]::Abs(($read['b'] - $until).TotalSeconds) -lt 1) $true
    Test-Case 'a spent account is skipped' ($null -eq (Select-FreeAccount -Exclude 'main' -HomeDir $fakeHome)) $true
    Set-AccountLimited -Name 'b' -Until (Get-Date).AddMinutes(-1)
    Test-Case 'one whose reset has passed is free again' (Select-FreeAccount -Exclude 'main' -HomeDir $fakeHome).name 'b'
    Set-AccountLimited -Name 'main' -Until $until
    Test-Case 'the record keeps every account' (@((Read-AccountLimits).Keys | Sort-Object) -join ',') 'b,main'
    Set-Content -LiteralPath (Get-AccountLimitsFile) -Value 'not json'
    Test-Case 'an unreadable record means nothing known' ((Read-AccountLimits).Count) 0
    Test-Case 'a machine with one account has nowhere to go' `
        ($null -eq (Select-FreeAccount -Exclude 'main' -HomeDir (Join-Path $root 'nobody'))) $true

    Write-Host 'a new login in a spent account''s directory'
    # What happened on 2026-11-17: b ran out, then another subscription was logged into
    # ~/.claude-b. The record was about the old login; the new one has its whole allowance.
    Remove-Item -LiteralPath (Get-AccountLimitsFile) -Force
    Set-Content -LiteralPath (Join-Path $b '.claude.json') -Value '{ "oauthAccount": { "accountUuid": "old-login" } }'
    Test-Case 'the login is read from the account''s directory' (Get-AccountLogin -Dir $b) 'old-login'
    Set-AccountLimited -Name 'b' -Until (Get-Date).AddMinutes(90) -Accounts $accounts
    Test-Case 'the record keeps which login ran out' (Read-AccountLimitRecords)['b'].login 'old-login'
    Test-Case 'same login: still spent' ($null -eq (Select-FreeAccount -Exclude 'main' -HomeDir $fakeHome)) $true
    Set-Content -LiteralPath (Join-Path $b '.claude.json') -Value '{ "oauthAccount": { "accountUuid": "new-login" } }'
    Test-Case 'another login: free at once' (Select-FreeAccount -Exclude 'main' -HomeDir $fakeHome).name 'b'
    Test-Case 'and no longer shown as spent' ((Read-AccountLimits -Accounts $accounts).ContainsKey('b')) $false
    Set-Content -LiteralPath (Get-AccountLimitsFile) -Value ('{ "b": "' + (Get-Date).AddMinutes(90).ToUniversalTime().ToString('o') + '" }')
    Test-Case 'a record from before logins were kept still counts' ((Read-AccountLimits -Accounts $accounts).ContainsKey('b')) $true

    Write-Host 'a new login ends a wait'
    Set-Content -LiteralPath (Join-Path $b '.claude.json') -Value '{ "oauthAccount": { "accountUuid": "first" } }'
    $savedClaudeHome = $env:PHASEKIT_CLAUDE_HOME
    $env:PHASEKIT_CLAUDE_HOME = $fakeHome
    try {
        $relog = Start-ThreadJob -ArgumentList (Join-Path $b '.claude.json') -ScriptBlock {
            param($f) Start-Sleep -Seconds 2; Set-Content -LiteralPath $f -Value '{ "oauthAccount": { "accountUuid": "second" } }'
        }
        $log = Join-Path $root 'relog.log'
        $started = Get-Date
        Wait-UntilDeadline -Deadline (Get-Date).AddMinutes(30) -LogPath $log -Account 'b' -PollSeconds 1
        $relog | Wait-Job | Remove-Job
        Test-Case 'the wait ends when the login changes' (((Get-Date) - $started).TotalSeconds -lt 15) $true
        Test-Case 'and says why' ((Get-Content -LiteralPath $log -Raw) -match 'now holds another login') $true
    }
    finally { $env:PHASEKIT_CLAUDE_HOME = $savedClaudeHome }
}
finally {
    $env:PHASEKIT_HOME = $savedHome
    $env:CLAUDE_CONFIG_DIR = $savedConfig
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails) {
    Write-Host "$fails failed." -ForegroundColor Red
    exit 1
}
Write-Host 'all green.' -ForegroundColor Green
