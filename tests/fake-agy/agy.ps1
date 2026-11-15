<#
    A stand-in for the Antigravity CLI (agy), in the stream-json shape measured against agy
    1.5.9: {"event":"init"|"step_update"|"result", ...} with a conversation_id. It does, in
    the current directory, what each kind of call would:

      run      (no --conversation, no --mode plan)  commits the target's work, ticks the box
      resume   (--conversation <id>)                creates good.txt and commits it
      review   (--mode plan)                        answers PK_REVIEWS' next verdict
      fresh    (no --conversation, and the prompt   a fix round that changed CLI: creates
                says "was rejected" or "failed")    good.txt and commits it

    PK_AGY_LIMIT=1 makes every call fail with a quota error, the way a spent plan would.
    Calls go to $env:PK_FAKE_DIR/calls.txt as "agy-<kind> <model> <mode>", prompts to
    prompts.txt, and the --settings JSON to settings.txt.
#>
$a = @($args)
function Get-Arg([string] $Name) { $i = [array]::IndexOf($a, $Name); if ($i -ge 0 -and $i + 1 -lt $a.Count) { return [string] $a[$i + 1] } return '' }
$dir = $env:PK_FAKE_DIR
$prompt = Get-Arg '-p'
$conv = Get-Arg '--conversation'
$mode = Get-Arg '--mode'
$kind = if ($mode -eq 'plan') { 'review' } elseif ($conv) { 'resume' } elseif ($prompt -match 'was rejected|they failed|rejected it') { 'fresh' } else { 'run' }
Add-Content -LiteralPath (Join-Path $dir 'calls.txt') -Value ("agy-{0} {1} {2}" -f $kind, (Get-Arg '--model'), $mode)
Add-Content -LiteralPath (Join-Path $dir 'prompts.txt') -Value ("=== agy-$kind`n$prompt")
Add-Content -LiteralPath (Join-Path $dir 'settings.txt') -Value (Get-Arg '--settings')
$count = @(Get-Content -LiteralPath (Join-Path $dir 'calls.txt') | Where-Object { $_ -like "agy-$kind *" }).Count

$cid = if ($conv) { $conv } else { [guid]::NewGuid().ToString() }
function Out-Event($o) { $o | ConvertTo-Json -Depth 8 -Compress }

if ($env:PK_AGY_LIMIT -eq '1') {
    Out-Event @{ event = 'result'; result = @{ conversation_id = $cid; status = 'ERROR'; response = ''; error = 'RESOURCE_EXHAUSTED: weekly quota for Gemini models reached' } }
    [Console]::Error.WriteLine('error: RESOURCE_EXHAUSTED: weekly quota for Gemini models reached')
    exit 1
}

Out-Event @{ event = 'init'; conversation_id = $cid; init = @{ model = (Get-Arg '--model'); cwd = (Get-Location).Path } }
Out-Event @{ event = 'step_update'; step_update = @{ conversation_id = $cid; step_index = 0; state = 'DONE'; step_type = 'user_input' } }

$text = ''
switch ($kind) {
    'run' {
        Set-Content -LiteralPath 'work.txt' -Value 'work'
        $plan = Get-Content -LiteralPath 'PLAN.md' -Raw
        Set-Content -LiteralPath 'PLAN.md' -Value ($plan -replace '- \[ \] A\.1', '- [x] A.1') -NoNewline
        git add -A 2>&1 | Out-Null
        git commit -q -m 'feat: A.1' 2>&1 | Out-Null
        Out-Event @{ event = 'step_update'; step_update = @{ conversation_id = $cid; step_index = 1; state = 'DONE'; step_type = 'tool'; tool_name = 'run_command'; tool_info = @{ name = 'run_command'; parameters = @{ CommandLine = 'git commit -m "feat: A.1"' }; output = 'Command exited with code 0.' } } }
        $text = "Done on Antigravity.`n`nLESSONS`nNONE"
    }
    { $_ -in @('resume', 'fresh') } {
        Set-Content -LiteralPath 'good.txt' -Value 'fixed'
        git add -A 2>&1 | Out-Null
        git commit -q -m 'fix: A.1' 2>&1 | Out-Null
        $text = 'Fixed it on Antigravity.'
    }
    'review' {
        $verdicts = @(($env:PK_REVIEWS -split ',') | Where-Object { $_ })
        $v = if ($count -le $verdicts.Count) { $verdicts[$count - 1] } else { 'PASS' }
        $text = "Read the diff.`n`nVERDICT: $v`n1. work.txt:1 - wrong - the task says so"
    }
}
Out-Event @{ event = 'step_update'; step_update = @{ conversation_id = $cid; step_index = 2; state = 'DONE'; step_type = 'agent_response'; text_delta = $text } }
Out-Event @{ event = 'result'; result = @{ conversation_id = $cid; status = 'SUCCESS'; response = $text; num_turns = 1 } }
exit 0
