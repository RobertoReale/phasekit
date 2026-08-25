# PhaseKit — shared functions. Dot-sourced by bin/phasekit.ps1, so everything here
# runs in that script's scope and $script: variables are shared with it.

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

function Find-PhaseKitConfig {
    <#
        Walks up from a starting directory looking for phasekit.json, so the tool can be
        invoked from anywhere inside the project rather than only from its root.
    #>
    param([string] $From = (Get-Location).Path)

    $dir = (Resolve-Path $From).Path
    while ($dir) {
        $candidate = Join-Path $dir 'phasekit.json'
        if (Test-Path $candidate) { return $candidate }
        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

function Get-PhaseKitConfig {
    param([string] $Path)

    if (-not $Path) { $Path = Find-PhaseKitConfig }
    if (-not $Path) {
        throw "No phasekit.json found here or in any parent directory. Run: phasekit init"
    }

    $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $configDir = Split-Path -Parent (Resolve-Path $Path).Path

    # Defaults. Everything the user did not set gets a value that works for a
    # single-repo project, which is the common case.
    $cfg = [ordered]@{
        configPath       = $Path
        configDir        = $configDir
        # Where the agent is launched. Must be a directory from which every path the
        # plan mentions is reachable — with a separate notes repo, that is their parent.
        workingDir       = $configDir
        # The git repository that receives the branch and the commits.
        codeDir          = $configDir
        plan             = 'PLAN.md'
        prompts          = 'PROMPTS.md'
        logDir           = '.phasekit/logs'
        model            = 'opus'
        effort           = 'high'
        branchPrefix     = 'plan/phase-'
        requireCleanTree = $true
        maxRetries       = 6
        waitMinutes      = 20
        gates            = @()
    }

    foreach ($k in @('workingDir', 'codeDir', 'plan', 'prompts', 'logDir', 'model', 'effort', 'branchPrefix')) {
        if ($raw.PSObject.Properties.Name -contains $k -and $raw.$k) { $cfg[$k] = $raw.$k }
    }
    if ($raw.PSObject.Properties.Name -contains 'requireCleanTree') {
        $cfg.requireCleanTree = [bool] $raw.requireCleanTree
    }
    if ($raw.usageLimit) {
        if ($raw.usageLimit.maxRetries) { $cfg.maxRetries = [int] $raw.usageLimit.maxRetries }
        if ($raw.usageLimit.waitMinutes) { $cfg.waitMinutes = [int] $raw.usageLimit.waitMinutes }
    }
    if ($raw.gates) { $cfg.gates = @($raw.gates) }

    # Relative paths in the config are relative to the config file, never to the shell's
    # current directory — otherwise the same command means different things depending on
    # where it was typed.
    foreach ($k in @('workingDir', 'codeDir', 'logDir', 'plan', 'prompts')) {
        if (-not [System.IO.Path]::IsPathRooted($cfg[$k])) {
            $cfg[$k] = Join-Path $configDir $cfg[$k]
        }
        # Collapse the "." and ".." segments a relative config produces, so the paths
        # printed at the top of every run are readable rather than a trail of breadcrumbs.
        $cfg[$k] = [System.IO.Path]::GetFullPath($cfg[$k])
    }

    return [pscustomobject] $cfg
}

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

function Read-PhasePrompt {
    <#
        Pulls the fenced block that follows "## Phase N" out of PROMPTS.md and returns it
        verbatim. Passing the text itself rather than "go read section N of that file"
        removes a step where the agent can pick the wrong block — a failure that looks
        like a successful run right up until you read the diff.
    #>
    param(
        [Parameter(Mandatory)] [string] $PromptsFile,
        [Parameter(Mandatory)] [string] $Phase
    )

    if (-not (Test-Path $PromptsFile)) { throw "Prompts file not found: $PromptsFile" }
    $lines = Get-Content -LiteralPath $PromptsFile

    $escaped = [regex]::Escape($Phase)
    $headingPattern = "^##\s+(Phase\s+)?$escaped\b"

    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $headingPattern) { $start = $i; break }
    }
    if ($start -lt 0) { return $null }

    # First fenced block after the heading, stopping at the next heading of the same
    # level so a phase with no block does not silently borrow the next phase's.
    $inFence = $false
    $body = New-Object System.Collections.Generic.List[string]
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if (-not $inFence -and $line -match '^##\s') { break }
        if ($line -match '^\s*```') {
            if ($inFence) { break }
            $inFence = $true
            continue
        }
        if ($inFence) { $body.Add($line) }
    }
    if ($body.Count -eq 0) { return $null }
    return ($body -join "`n").Trim()
}

function Build-PhasePrompt {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $Phase
    )

    $block = Read-PhasePrompt -PromptsFile $Config.prompts -Phase $Phase
    $planName = Split-Path -Leaf $Config.plan
    $promptsName = Split-Path -Leaf $Config.prompts
    $isTask = $Phase -match '\.'

    # A phase gets its own block; an individual task usually does not, and writing one per
    # task would be twenty near-identical copies waiting to drift apart. So a target with a
    # dot in it falls back to the generic "## task" block, with {{TASK}} substituted.
    if (-not $block -and $isTask) {
        $generic = Read-PhasePrompt -PromptsFile $Config.prompts -Phase 'task'
        if ($generic) {
            $block = $generic -replace '\{\{TASK\}\}', $Phase
            Write-Host "Using the generic '## task' block for $Phase." -ForegroundColor DarkGray
        }
    }

    if (-not $block) {
        # No block for this phase: fall back to pointing at the file. Say so loudly,
        # because a missing block is usually a typo in the phase id, not a design choice.
        Write-Host "No '## Phase $Phase' block in $promptsName — falling back to a pointer prompt." -ForegroundColor Yellow
        return "Read $planName and $promptsName, then carry out the Phase $Phase prompt from $promptsName exactly as it is written there, including its CHECK FIRST step. Do not go beyond that phase."
    }

    $what = if ($isTask) { "task $Phase" } else { "phase $Phase" }
    $header = "You are executing $what of $planName, unattended, in a headless session.`n" +
              "The instructions below are the prompt for it, copied verbatim from $promptsName.`n" +
              "Follow them exactly. Do not go beyond what they ask for.`n`n"

    return $header + $block
}

# ---------------------------------------------------------------------------
# Session identity
# ---------------------------------------------------------------------------
#
# `claude -c` means "the most recent conversation in this directory". That is not
# necessarily the one this script started: an interactive session open in the same folder
# outranks the headless one, and the answer then lands in the wrong conversation with no
# error printed anywhere. So the session id is captured from the stream and written to
# disk, and every resume uses --resume <id>.

function Get-SessionFile {
    param($Config, [string] $Phase)
    return (Join-Path $Config.logDir ("phase-{0}.session" -f ($Phase -replace '[^\w.-]', '_')))
}

function Get-PinnedSession {
    param($Config, [string] $Phase)
    $f = Get-SessionFile -Config $Config -Phase $Phase
    if (Test-Path $f) { return (Get-Content -LiteralPath $f -TotalCount 1).Trim() }
    return $null
}

function Get-ResumeArgs {
    param([string] $SessionId)
    if ($SessionId) { return @('--resume', $SessionId) }
    Write-Host 'No pinned session id — falling back to -c, which may resume the wrong conversation.' -ForegroundColor Yellow
    return @('-c')
}

# ---------------------------------------------------------------------------
# Running the agent
# ---------------------------------------------------------------------------

# What a usage-limit stop looks like, as opposed to a real failure. A limit is worth
# waiting out; a failing test is not worth retrying blindly.
$script:LimitPattern = 'usage limit|session limit|weekly limit|rate limit|resets at|resets \d|429'

function Get-ResetWaitMinutes {
    <#
        The limit message usually says when the allowance comes back:

            You've hit your session limit ⎿ resets 10:50pm (Europe/Rome)

        Waiting a fixed interval instead wastes retries — six twenty-minute waits is two
        hours, and a reset three hours out then exhausts every attempt without ever
        reaching it. So: sleep until the announced time when there is one, and fall back
        to the fixed interval when there is not.

        Returns $null when no reset time can be read.
    #>
    param([Parameter(Mandatory)] [string] $LogTail)

    # 12-hour with am/pm, or 24-hour. Take the LAST match: the tail may contain older
    # limit messages from earlier in the same run.
    # A bare number after "resets" is not enough — "resets 23 minutes from now" would be
    # read as 23:00 — so require either explicit minutes or a meridiem.
    $m = [regex]::Matches($LogTail, '(?i)resets\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?')
    $g = $null
    for ($i = $m.Count - 1; $i -ge 0; $i--) {
        if ($m[$i].Groups[2].Success -or $m[$i].Groups[3].Success) { $g = $m[$i].Groups; break }
    }
    if (-not $g) { return $null }

    $hour = [int] $g[1].Value
    $min = if ($g[2].Success) { [int] $g[2].Value } else { 0 }
    $mer = $g[3].Value.ToLowerInvariant()

    if ($mer -eq 'pm' -and $hour -lt 12) { $hour += 12 }
    if ($mer -eq 'am' -and $hour -eq 12) { $hour = 0 }
    if ($hour -gt 23 -or $min -gt 59) { return $null }

    $now = Get-Date
    $target = $now.Date.AddHours($hour).AddMinutes($min)
    # A reset time already past means it is tomorrow's.
    if ($target -le $now) { $target = $target.AddDays(1) }

    # A couple of minutes of margin: resuming at the exact reset second tends to fail again.
    $wait = [math]::Ceiling(($target - $now).TotalMinutes) + 2

    # The message reports the reset in its own timezone, which may not be this machine's.
    # A wildly implausible answer means the parse was wrong, so refuse it rather than
    # sleeping for half a day.
    if ($wait -le 0 -or $wait -gt 720) { return $null }
    return [int] $wait
}

# The prompt used to pick up an interrupted conversation. It deliberately asks the agent
# to re-establish reality from the gates and the git log rather than trusting its own
# memory of what it had finished.
$script:ContinuePrompt = @'
Continue where you stopped. First re-read the progress ledger and run the gates to
establish what actually landed before the interruption — check `git log` and `git status`,
because a task can be half-done with edits on disk and no commit. Then carry on with the
remaining tasks of this phase under the same rules. Do not redo work that is already
committed, and do not start the next phase.
'@

function Invoke-Agent {
    <#
        Runs claude and renders its stream-json output as one readable line per event.
        Plain text output prints nothing until the very end of a run that can last an
        hour, which is indistinguishable from a hang.
    #>
    param(
        [Parameter(Mandatory)] [string[]] $ClaudeArgs,
        [Parameter(Mandatory)] [string]   $LogPath,
        [Parameter(Mandatory)] [string]   $SessionFile
    )

    Write-Host ''
    Write-Host ('-' * 72) -ForegroundColor DarkGray
    Write-Host "claude $($ClaudeArgs -join ' ')" -ForegroundColor DarkGray
    Write-Host ('-' * 72) -ForegroundColor DarkGray

    & claude @ClaudeArgs 2>&1 | ForEach-Object {
        $line = [string] $_
        Add-Content -LiteralPath $LogPath -Value $line

        if ($line -notmatch '^\s*\{') {
            if ($line.Trim()) { Write-Host $line }
            return
        }

        try { $ev = $line | ConvertFrom-Json } catch { return }
        $t = (Get-Date).ToString('HH:mm:ss')

        if ($ev.session_id -and $ev.session_id -ne $script:SessionId) {
            $script:SessionId = $ev.session_id
            Set-Content -LiteralPath $SessionFile -Value $ev.session_id
        }

        switch ($ev.type) {
            'system' {
                if ($ev.subtype -eq 'init') {
                    Write-Host "$t  session $($ev.session_id)  cwd $($ev.cwd)" -ForegroundColor DarkGray
                }
            }
            'assistant' {
                foreach ($c in $ev.message.content) {
                    switch ($c.type) {
                        'text' {
                            if ($c.text.Trim()) { Write-Host "$t  $($c.text.Trim())" }
                        }
                        'tool_use' {
                            $detail = switch ($c.name) {
                                'Bash' { $c.input.command }
                                'PowerShell' { $c.input.command }
                                'Read' { $c.input.file_path }
                                'Edit' { $c.input.file_path }
                                'Write' { $c.input.file_path }
                                'Grep' { $c.input.pattern }
                                'Glob' { $c.input.pattern }
                                'Task' { $c.input.description }
                                default { '' }
                            }
                            $detail = ([string] $detail) -replace '\s+', ' '
                            if ($detail.Length -gt 100) { $detail = $detail.Substring(0, 100) + '...' }
                            Write-Host "$t  -> $($c.name) $detail" -ForegroundColor DarkCyan
                        }
                    }
                }
            }
            'result' {
                $cost = if ($ev.total_cost_usd) { '  $' + ([math]::Round($ev.total_cost_usd, 2)) } else { '' }
                Write-Host ''
                Write-Host "$t  DONE  turns=$($ev.num_turns)$cost" -ForegroundColor Green
                if ($ev.result) { Write-Host $ev.result }
            }
        }
    }
    return $LASTEXITCODE
}

function Invoke-AgentWithLimitRetry {
    <#
        Runs the agent, and when it stops because the subscription allowance ran out,
        waits and resumes the SAME conversation so it carries on from the task it was on
        instead of restarting the phase. Any other exit stops immediately and shows the
        tail of the log, because "the agent stopped to ask a question" looks exactly like
        a failure from the outside and needs to be readable.
    #>
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $Phase,
        [Parameter(Mandatory)] [string[]] $FirstArgs,
        [Parameter(Mandatory)] [string] $LogPath,
        [Parameter(Mandatory)] [string] $SessionFile,
        [Parameter(Mandatory)] [string[]] $Common
    )

    $exit = Invoke-Agent -ClaudeArgs $FirstArgs -LogPath $LogPath -SessionFile $SessionFile

    $attempt = 0
    while ($exit -ne 0 -and $attempt -lt $Config.maxRetries) {

        # -Tail and -Raw are mutually exclusive on Get-Content, so join the lines by hand.
        $tail = if (Test-Path $LogPath) { (Get-Content -LiteralPath $LogPath -Tail 40) -join "`n" } else { '' }

        if ($tail -notmatch $script:LimitPattern) {
            Write-Host ''
            Write-Host "Stopped for a reason that is not a usage limit (exit $exit)." -ForegroundColor Red
            Write-Host 'Last lines of the log — an agent that stops to ask a question looks like this too:' -ForegroundColor Red
            Write-Host $tail
            Write-Host ''
            Write-Host "Full log: $LogPath" -ForegroundColor Red
            Write-Host "Answer it without losing its context:  phasekit reply $Phase -Text `"your answer`"" -ForegroundColor Cyan
            return $exit
        }

        $attempt++
        $announced = Get-ResetWaitMinutes -LogTail $tail
        $wait = if ($announced) { $announced } else { $Config.waitMinutes }
        $source = if ($announced) { 'until the announced reset' } else { 'fixed interval' }
        $resumeAt = (Get-Date).AddMinutes($wait).ToString('HH:mm')

        Write-Host ''
        Write-Host "Usage limit reached. Waiting $wait min ($source), resuming at ~$resumeAt (attempt $attempt of $($Config.maxRetries))." -ForegroundColor Yellow
        Start-Sleep -Seconds ($wait * 60)

        $resume = (Get-ResumeArgs -SessionId $script:SessionId) + @('-p', $script:ContinuePrompt) + $Common
        $exit = Invoke-Agent -ClaudeArgs $resume -LogPath $LogPath -SessionFile $SessionFile
    }

    return $exit
}

# ---------------------------------------------------------------------------
# Merging a finished phase
# ---------------------------------------------------------------------------

function Get-MainBranch {
    <#
        The branch a finished phase merges into. Configurable, because guessing wrong here
        is the one mistake in this tool that writes to a branch people pull from.
    #>
    param($Config)

    if ($Config.PSObject.Properties.Name -contains 'mainBranch' -and $Config.mainBranch) {
        return $Config.mainBranch
    }
    $head = git -C $Config.codeDir symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>$null
    if ($head) { return ($head -replace '^origin/', '') }
    foreach ($candidate in @('main', 'master')) {
        if (git -C $Config.codeDir rev-parse --verify --quiet $candidate) { return $candidate }
    }
    throw 'Cannot work out the main branch. Set "mainBranch" in phasekit.json.'
}

function Test-PhaseReady {
    <#
        Everything that must be true before a phase branch is allowed to become the truth.
        These are exactly the checks a human does when they bother: gates green on the
        branch itself, nothing uncommitted, every task in the phase ticked, and at least
        one commit to show for it.

        Returns a report object. It never merges and never modifies anything.
    #>
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $Phase
    )

    $branch = "$($Config.branchPrefix)$Phase"
    $problems = New-Object System.Collections.Generic.List[string]

    if (-not (git -C $Config.codeDir rev-parse --verify --quiet $branch)) {
        $problems.Add("branch $branch does not exist")
        return [pscustomobject]@{ ok = $false; branch = $branch; problems = $problems; commits = @() }
    }

    $current = (git -C $Config.codeDir branch --show-current).Trim()
    if ($current -ne $branch) { $problems.Add("not on $branch (currently on $current)") }

    $dirty = @(git -C $Config.codeDir status --porcelain)
    if ($dirty.Count -gt 0) {
        $problems.Add("$($dirty.Count) uncommitted change(s) — a task ended without committing")
    }

    # Commits the phase produced, measured from the base recorded when the run started, or
    # from the fork point if that file is gone.
    $baseFile = Join-Path $Config.logDir ("phase-{0}.base" -f ($Phase -replace '[^\w.-]', '_'))
    $base = if (Test-Path $baseFile) { (Get-Content -LiteralPath $baseFile -TotalCount 1).Trim() }
            else { (git -C $Config.codeDir merge-base (Get-MainBranch -Config $Config) $branch).Trim() }

    $commits = @(git -C $Config.codeDir log --oneline "$base..$branch")
    if ($commits.Count -eq 0) { $problems.Add('the branch has no commits on it') }

    # Every task belonging to this phase must be ticked. An unticked task with work behind
    # it is the same disagreement as a ticked task with none — both mean the ledger is not
    # describing the repository.
    $unticked = @()
    if (Test-Path $Config.plan) {
        $escaped = [regex]::Escape($Phase)
        foreach ($line in Get-Content -LiteralPath $Config.plan) {
            if ($line -match "^\s*- \[( |x)\]\s+$escaped\.") {
                if ($Matches[1] -ne 'x') { $unticked += ($line -replace '^\s*- \[ \]\s*', '') }
            }
        }
    }
    if ($unticked.Count -gt 0) {
        $problems.Add("$($unticked.Count) task(s) in this phase not ticked: " + ($unticked -join '; '))
    }

    return [pscustomobject]@{
        ok       = ($problems.Count -eq 0)
        branch   = $branch
        base     = $base
        commits  = $commits
        problems = $problems
    }
}

# ---------------------------------------------------------------------------
# Gates
# ---------------------------------------------------------------------------

function Invoke-Gates {
    <#
        Runs the project's gates without an agent, so a human can check the state of the
        tree for free instead of spending a turn asking.
    #>
    param([Parameter(Mandatory)] $Config)

    if (-not $Config.gates -or $Config.gates.Count -eq 0) {
        Write-Host 'No gates defined in phasekit.json.' -ForegroundColor Yellow
        return 0
    }

    $failed = 0
    foreach ($g in $Config.gates) {
        $cwd = if ($g.cwd) { Join-Path $Config.configDir $g.cwd } else { $Config.workingDir }
        if (-not (Test-Path $cwd)) {
            Write-Host ("  FAIL  {0,-22} directory not found: {1}" -f $g.name, $cwd) -ForegroundColor Red
            $failed++
            continue
        }

        Push-Location $cwd
        try {
            # Reset first: a gate that is a cmdlet rather than an executable leaves
            # $LASTEXITCODE untouched, so a stale value from an earlier command would be
            # read as this gate's result.
            $global:LASTEXITCODE = 0
            $out = Invoke-Expression $g.run 2>&1
            $ok = $?
            $code = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } elseif ($ok) { 0 } else { 1 }
        } catch {
            $out = $_.Exception.Message
            $code = 1
        } finally {
            Pop-Location
        }

        if ($code -eq 0) {
            Write-Host ("  PASS  {0,-22} {1}" -f $g.name, $g.run) -ForegroundColor Green
        } else {
            $failed++
            Write-Host ("  FAIL  {0,-22} {1}  (exit {2})" -f $g.name, $g.run, $code) -ForegroundColor Red
            $lastLines = ($out | Select-Object -Last 8) -join "`n"
            if ($lastLines.Trim()) { Write-Host $lastLines -ForegroundColor DarkGray }
        }
    }
    return $failed
}
