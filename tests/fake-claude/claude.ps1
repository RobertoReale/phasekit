<#
    A stand-in for the claude CLI, for tests that drive `phasekit auto` end to end without
    spending anything. It speaks the stream-json the runner reads and does, in the current
    directory, what each kind of call would do:

      run      (no --resume)       commits the target's work and ticks its ledger box
      resume   (--resume)          a fix round: on the call PK_FIX_AT names (1 = first),
                                   creates good.txt and commits it
      review   (--allowedTools)    answers with the next verdict from PK_REVIEWS
                                   (PASS, FAIL or NONE); PK_TAMPER=1 makes it write a file

    Every call is appended to $env:PK_FAKE_DIR/calls.txt as "<kind> <model> <effort>", and
    every prompt to prompts.txt, so a test can say what was asked of whom.
#>
$a = @($args)
function Get-Arg([string] $Name) { $i = [array]::IndexOf($a, $Name); if ($i -ge 0 -and $i + 1 -lt $a.Count) { return [string] $a[$i + 1] } return '' }

$dir = $env:PK_FAKE_DIR
$kind = if ($a -contains '--allowedTools') { 'review' } elseif ($a -contains '--resume') { 'resume' } else { 'run' }
Add-Content -LiteralPath (Join-Path $dir 'calls.txt') -Value ("{0} {1} {2}" -f $kind, (Get-Arg '--model'), (Get-Arg '--effort'))
Add-Content -LiteralPath (Join-Path $dir 'prompts.txt') -Value ("=== $kind`n" + (Get-Arg '-p'))
$count = @(Get-Content -LiteralPath (Join-Path $dir 'calls.txt') | Where-Object { $_ -like "$kind *" }).Count

$sid = if ($kind -eq 'resume') { Get-Arg '--resume' } else { [guid]::NewGuid().ToString() }
'{"type":"system","subtype":"init","session_id":"' + $sid + '","cwd":"."}'

$text = ''
switch ($kind) {
    'run' {
        Set-Content -LiteralPath 'work.txt' -Value 'work'
        $plan = Get-Content -LiteralPath 'PLAN.md' -Raw
        Set-Content -LiteralPath 'PLAN.md' -Value ($plan -replace '- \[ \] A\.1', '- [x] A.1') -NoNewline
        git add -A 2>&1 | Out-Null
        git commit -q -m 'feat: A.1' 2>&1 | Out-Null
        $text = "Done.`n`nLESSONS`nNONE"
    }
    'resume' {
        $at = if ($env:PK_FIX_AT) { [int] $env:PK_FIX_AT } else { 1 }
        if ($count -eq $at) {
            Set-Content -LiteralPath 'good.txt' -Value 'fixed'
            git add -A 2>&1 | Out-Null
            git commit -q -m 'fix: A.1' 2>&1 | Out-Null
            $text = 'Fixed it. Finding 1 was real.'
        }
        else { $text = 'Tried, could not fix it.' }
    }
    'review' {
        if ($env:PK_TAMPER -eq '1') { Set-Content -LiteralPath 'tampered.txt' -Value 'x' }
        $verdicts = @(($env:PK_REVIEWS -split ',') | Where-Object { $_ })
        $v = if ($count -le $verdicts.Count) { $verdicts[$count - 1] } else { 'PASS' }
        $text = if ($v -eq 'NONE') { 'I looked around and have opinions.' }
                else { "Looked at the diff.`n`nVERDICT: $v`n1. work.txt:1 - the work is wrong - the task says so" }
    }
}
[pscustomobject]@{ type = 'result'; subtype = 'success'; result = $text; session_id = $sid } | ConvertTo-Json -Compress
exit 0
