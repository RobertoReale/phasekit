<#
    Lessons: what one agent learned reaching the next ones. Parsing the LESSONS block,
    the scoring rules, the store on disk, the prompt section and collection from a real
    log. Most cases are the ones that must refuse: a wrong lesson handed to every later
    agent costs more than a missing one.

        pwsh -NoProfile -File tests/lessons.tests.ps1
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

$root = Join-Path ([IO.Path]::GetTempPath()) ('phasekit-lessons-test-' + [guid]::NewGuid().ToString('N'))
$logs = Join-Path $root 'logs'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
$cfg = [pscustomobject]@{ logDir = $logs; lessons = $true; lessonsMax = 30; lessonsMaxChars = 6000; handoff = $true; autoSequence = @('A.1', 'A.2') }

$good = 'ADD: when the browser suite runs right after another | restart.spec fails once with "browser is shutting down"; rerun it alone before suspecting your change | evidence: tests/e2e/restart.spec.ts, logs of M4.3 and M6.2'

try {
    Write-Host 'reading the LESSONS block'

    $p = ConvertFrom-LessonOps -Text "Report.`n`nLESSONS`n$good"
    Test-Case 'a well-formed ADD is read' @($p.ops).Count 1
    Test-Case 'its condition loses the word when' @($p.ops)[0].when 'the browser suite runs right after another'
    Test-Case 'its evidence loses the label' (@($p.ops)[0].evidence -like 'tests/e2e/restart.spec.ts*') 'True'
    Test-Case 'no block, nothing found' (ConvertFrom-LessonOps -Text 'Just a report.').found 'False'
    Test-Case 'NONE is not an operation and not an error' (@((ConvertFrom-LessonOps -Text "LESSONS`nNONE").rejected).Count) 0
    $bare = ConvertFrom-LessonOps -Text "LESSONS`nCONFIRM L1"
    Test-Case 'CONFIRM L1 with no colon is still a confirmation' "$(@($bare.ops).Count)|$(@($bare.ops)[0].op)|$(@($bare.ops)[0].id)" '1|CONFIRM|L1'
    Test-Case 'but prose is still not an operation' (@((ConvertFrom-LessonOps -Text "LESSONS`nConfirmed it twice").rejected).Count) 1
    Test-Case 'a heading and a list marker are accepted' @((ConvertFrom-LessonOps -Text "## LESSONS`n- $good").ops).Count 1
    $fence = ([string] [char] 96) * 3
    Test-Case 'a code fence around the block is ignored' @((ConvertFrom-LessonOps -Text "LESSONS`n$fence`n$good`n$fence").ops).Count 1
    Test-Case 'a LESSONS line with nothing after it reads nothing' @((ConvertFrom-LessonOps -Text "$good`nLESSONS").ops).Count 0
    # The format quoted earlier in the message is not the block: only the last one counts.
    $quoted = "The format is:`nLESSONS`nADD: when x | y | evidence: z`n`nMy report.`n`nLESSONS`nNONE"
    Test-Case 'only the last block counts' @((ConvertFrom-LessonOps -Text $quoted).ops).Count 0

    $bad = ConvertFrom-LessonOps -Text ("LESSONS`nADD: when x | no evidence part`nADD: when | y | evidence: z`nCONFIRM: helped`n" +
        "WRONG L2:`nADD L4: when x | y | evidence: z`nFORGET L1: stale`nsome prose`nADD: when x | " + ('y' * 401) + ' | evidence: z')
    Test-Case 'every malformed line is refused' @($bad.rejected).Count 8
    Test-Case 'and nothing malformed gets through' @($bad.ops).Count 0
    Test-Case 'a missing part is named' ($bad.rejected[0].why -match 'three parts') 'True'
    Test-Case 'an empty condition is named' ($bad.rejected[1].why -match 'empty: when') 'True'
    Test-Case 'CONFIRM without an id is refused' ($bad.rejected[2].why -match 'needs a lesson id') 'True'
    Test-Case 'WRONG without evidence is refused' ($bad.rejected[3].why -match 'evidence') 'True'
    Test-Case 'an over-long lesson is refused' ($bad.rejected[7].why -match 'lesson over 400') 'True'

    Write-Host 'the scoring rules'

    $s = New-LessonStore
    $add = { param($t) @((ConvertFrom-LessonOps -Text "LESSONS`n$t").ops) }
    $r = Update-LessonStore -Store $s -Ops (& $add $good) -Source 'M4.3'
    Test-Case 'ADD creates L1' $s.lessons[0]['id'] 'L1'
    Test-Case 'starting at score 2' $s.lessons[0]['score'] 2
    $null = Update-LessonStore -Store $s -Ops (& $add 'CONFIRM L1: it was exactly this') -Source 'M4.3'
    Test-Case 'the adding target cannot confirm it' $s.lessons[0]['score'] 2
    $null = Update-LessonStore -Store $s -Ops (& $add 'CONFIRM L1: saw it too') -Source 'M6.2'
    Test-Case 'another target can' $s.lessons[0]['score'] 3
    $null = Update-LessonStore -Store $s -Ops (& $add 'CONFIRM L1: and again') -Source 'M6.2'
    Test-Case 'once per target' $s.lessons[0]['score'] 3
    $null = Update-LessonStore -Store $s -Ops (& $add ($good -replace 'when the browser suite runs right after another', 'when anything')) -Source 'M7.1'
    Test-Case 'the same lesson again is a confirmation, not a copy' "$(@($s.lessons).Count)/$($s.lessons[0]['score'])" '1/4'
    $null = Update-LessonStore -Store $s -Ops (& $add 'WRONG L1: it fails on main too, the cause is the port') -Source 'M7.2'
    Test-Case 'WRONG lowers by 2' $s.lessons[0]['score'] 2
    Test-Case 'and leaves a trace' (@($s.lessons[0]['history']).Count) 1
    $null = Update-LessonStore -Store $s -Ops (& $add 'EDIT L1: when port 3000 is taken | restart.spec fails; free the port | evidence: netstat in M7.2') -Source 'M7.2'
    Test-Case 'EDIT rewrites the lesson' $s.lessons[0]['when'] 'port 3000 is taken'
    Test-Case 'keeping its id and score' "$($s.lessons[0]['id'])/$($s.lessons[0]['score'])" 'L1/2'
    $null = Update-LessonStore -Store $s -Ops (& $add 'WRONG L1: still wrong') -Source 'M7.3'
    Test-Case 'at 0 it is retired' @($s.lessons).Count 0
    Test-Case 'and kept for the audit, with the reason' ($s.retired[0]['why'] -match 'contradicted by M7.3') 'True'
    $r = Update-LessonStore -Store $s -Ops (& $add 'CONFIRM L9: helped') -Source 'M7.3'
    Test-Case 'an unknown id is refused, not invented' ($r.refused[0] -match 'no such lesson') 'True'

    # Read twice, the same log must not count twice.
    $s2 = New-LessonStore
    $null = Update-LessonStore -Store $s2 -Ops (& $add $good) -Source 'A.1'
    $null = Update-LessonStore -Store $s2 -Ops (& $add 'CONFIRM L1: yes') -Source 'A.2'
    $null = Update-LessonStore -Store $s2 -Ops (& $add 'CONFIRM L1: yes') -Source 'A.2'
    $null = Update-LessonStore -Store $s2 -Ops (& $add $good) -Source 'A.1'
    Test-Case 'the same operation is applied once' "$(@($s2.lessons).Count)/$($s2.lessons[0]['score'])" '1/3'

    # Over the cap, the weakest goes.
    $s3 = New-LessonStore
    foreach ($i in 1..4) { $null = Update-LessonStore -Store $s3 -Ops (& $add "ADD: when case $i | lesson number $i | evidence: e$i") -Source "T.$i" -Max 3 }
    Test-Case 'the cap holds' @($s3.lessons).Count 3
    $null = Update-LessonStore -Store $s3 -Ops (& $add 'CONFIRM L2: helped') -Source 'T.9' -Max 3
    $null = Update-LessonStore -Store $s3 -Ops (& $add 'ADD: when case 5 | lesson number 5 | evidence: e5') -Source 'T.5' -Max 3
    Test-Case 'a confirmed lesson outlives newer unconfirmed ones' ((@($s3.lessons) | ForEach-Object { $_['id'] }) -contains 'L2') 'True'

    Write-Host 'the store on disk'

    $read = Read-LessonStore -Config $cfg
    Test-Case 'no file is an empty store' "$($read.ok)/$(@($read.store.lessons).Count)" 'True/0'
    Save-LessonStore -Config $cfg -Store $s2
    $back = Read-LessonStore -Config $cfg
    Test-Case 'a saved store reads back' "$($back.ok)/$($back.store.lessons[0]['id'])/$($back.store.nextId)" 'True/L1/2'
    Test-Case 'no temporary file is left behind' @(Get-ChildItem $logs -Filter '*.tmp').Count 0
    $null = Update-LessonStore -Store $back.store -Ops (& $add 'CONFIRM L1: from disk') -Source 'A.3'
    Test-Case 'a store read from disk can still be updated' $back.store.lessons[0]['score'] 4

    Set-Content -LiteralPath (Get-LessonsFile -Config $cfg) -Value '{ half a file'
    $broken = Read-LessonStore -Config $cfg
    Test-Case 'a broken file is reported' $broken.ok 'False'
    Test-Case 'the prompt still works without it' ((Get-LessonsNote -Config $cfg) -match '\(none yet\)') 'True'

    $log = Join-Path $logs 'phase-A.2-1.log'
    $final = [pscustomobject]@{ type = 'result'; result = "Done.`n`nLESSONS`n$good" } | ConvertTo-Json -Compress
    Set-Content -LiteralPath $log -Value @('{"type":"system"}', $final)
    $null = Update-LessonsFromLog -Config $cfg -Phase 'A.2' -LogPath $log
    Test-Case 'a broken file is never overwritten' (Get-Content -LiteralPath (Get-LessonsFile -Config $cfg) -Raw).Trim() '{ half a file'
    Remove-Item -LiteralPath (Get-LessonsFile -Config $cfg)

    Write-Host 'collecting from a log'

    $r = Update-LessonsFromLog -Config $cfg -Phase 'A.2' -LogPath $log
    Test-Case 'the block at the end of the final message is collected' (@((Read-LessonStore -Config $cfg).store.lessons).Count) 1
    $null = Update-LessonsFromLog -Config $cfg -Phase 'A.2' -LogPath $log
    Test-Case 'reading the same log again changes nothing' (@((Read-LessonStore -Config $cfg).store.lessons)[0]['score']) 2
    $cfg.lessons = $false
    Test-Case 'switched off, nothing is collected' ($null -eq (Update-LessonsFromLog -Config $cfg -Phase 'A.3' -LogPath $log)) 'True'
    Test-Case 'switched off, nothing is said' (Get-LessonsNote -Config $cfg) ''
    $cfg.lessons = $true
    Test-Case 'a missing log is not an error' ($null -eq (Update-LessonsFromLog -Config $cfg -Phase 'A.3' -LogPath (Join-Path $logs 'nope.log'))) 'True'

    Write-Host 'what the next agent is told'

    $note = Get-LessonsNote -Config $cfg
    Test-Case 'the lesson is in the prompt' ($note -match 'L1 \[score 2, from A\.2\] when the browser suite') 'True'
    Test-Case 'with its evidence' ($note -match 'evidence: tests/e2e/restart\.spec\.ts') 'True'
    Test-Case 'the gates stay the judge' ($note -match 'never replaces running a gate') 'True'
    Test-Case 'and the agent is told how to report' ($note -match 'first\s+line is LESSONS') 'True'
    $cfg.lessonsMaxChars = 50
    Test-Case 'the character budget holds' ((Get-LessonsNote -Config $cfg) -match '\(none yet\)') 'True'
    $cfg.lessonsMaxChars = 6000

    # The handoff carries the report, not the block: the prompt has the lessons already.
    $hand = Get-HandoffNote -Config $cfg -Phase 'A.3'
    $cfg.autoSequence = @('A.2', 'A.3')
    $hand = Get-HandoffNote -Config $cfg -Phase 'A.3'
    Test-Case 'the handoff keeps the report' ($hand -match 'Done\.') 'True'
    Test-Case 'and drops the LESSONS block' ($hand -match 'LESSONS') 'False'
    Test-Case 'the block is removed from a text' (Remove-LessonsBlock -Text "Report`nLESSONS`nNONE") 'Report'
    # A stop note keeps the end of the message, where the question is: the block must not
    # take that place.
    $tail = (Get-Content -LiteralPath $log) -join "`n"
    Test-Case 'a stop note does not carry the block' ((Get-AgentLastWords -LogTail $tail) -match 'LESSONS') 'False'
    Test-Case 'the collector does' ((Get-AgentLastWords -LogTail $tail -KeepLessons) -match 'LESSONS') 'True'

    Write-Host 'the settings'

    $cfgFile = Join-Path $root 'phasekit.json'
    Set-Content -LiteralPath $cfgFile -Value '{ "gates": [] }'
    $c = Get-PhaseKitConfig -Path $cfgFile
    Test-Case 'on by default, with a cap of 30' "$($c.lessons)/$($c.lessonsMax)/$($c.lessonsMaxChars)" 'True/30/6000'
    Set-Content -LiteralPath $cfgFile -Value '{ "gates": [], "lessons": false, "lessonsMax": 10 }'
    $c = Get-PhaseKitConfig -Path $cfgFile
    Test-Case 'both can be set' "$($c.lessons)/$($c.lessonsMax)" 'False/10'
    Set-Content -LiteralPath $cfgFile -Value '{ "gates": [], "lessonsMax": 0 }'
    $threw = $false
    try { $null = Get-PhaseKitConfig -Path $cfgFile } catch { $threw = $_.Exception.Message -match 'whole number above 0' }
    Test-Case 'a cap of 0 is refused' $threw 'True'

    Write-Host 'two writers at once'

    $cfg2 = [pscustomobject]@{ logDir = (Join-Path $root 'logs2'); lessons = $true; lessonsMax = 30 }
    $lib = Join-Path $PSScriptRoot '..' 'lib' 'PhaseKit.ps1'
    $jobs = foreach ($n in 1..4) {
        Start-Job -ScriptBlock {
            param($lib, $dir, $n)
            . $lib
            $c = [pscustomobject]@{ logDir = $dir; lessons = $true; lessonsMax = 30 }
            $ops = @((ConvertFrom-LessonOps -Text "LESSONS`nADD: when writer $n | lesson from writer $n | evidence: job $n").ops)
            Invoke-WithLessonLock -Config $c -Action {
                $read = Read-LessonStore -Config $c
                $null = Update-LessonStore -Store $read.store -Ops $ops -Source "W.$n"
                Save-LessonStore -Config $c -Store $read.store
            }
        } -ArgumentList $lib, $cfg2.logDir, $n
    }
    $null = $jobs | Wait-Job -Timeout 60 | Receive-Job -ErrorAction SilentlyContinue
    $jobs | Remove-Job -Force
    Test-Case 'four simultaneous writers lose nothing' @((Read-LessonStore -Config $cfg2).store.lessons).Count 4
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails -gt 0) { Write-Host "$fails failing" -ForegroundColor Red; exit 1 }
Write-Host 'all green.' -ForegroundColor Green
