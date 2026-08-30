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
        # Left empty on purpose: Get-MainBranch detects it from the repository, and a
        # default here would silently win over the detection on a repo whose main is
        # called something else.
        mainBranch       = ''
        requireCleanTree = $true
        maxRetries       = 6
        waitMinutes      = 20
        # Sound and a desktop notice when the sequence ends or stops to ask. On by
        # default: an unattended run nobody is watching is exactly the one whose stop
        # costs hours before anyone notices.
        notify           = $true
        gates            = @()
        # The targets `phasekit auto` walks, in order. See Get-AutoSequence.
        autoSequence     = @()
    }

    foreach ($k in @('workingDir', 'codeDir', 'plan', 'prompts', 'logDir', 'model', 'effort', 'branchPrefix', 'mainBranch')) {
        if ($raw.PSObject.Properties.Name -contains $k -and $raw.$k) { $cfg[$k] = $raw.$k }
    }
    if ($raw.PSObject.Properties.Name -contains 'requireCleanTree') {
        $cfg.requireCleanTree = [bool] $raw.requireCleanTree
    }
    if ($raw.PSObject.Properties.Name -contains 'notify') {
        $cfg.notify = [bool] $raw.notify
    }
    if ($raw.usageLimit) {
        if ($raw.usageLimit.maxRetries) { $cfg.maxRetries = [int] $raw.usageLimit.maxRetries }
        if ($raw.usageLimit.waitMinutes) { $cfg.waitMinutes = [int] $raw.usageLimit.waitMinutes }
    }
    if ($raw.gates) { $cfg.gates = @($raw.gates) }
    if ($raw.autoSequence) { $cfg.autoSequence = @($raw.autoSequence) }

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

    # Where the files actually are. A prompt block says "Read CLAUDE.md and PLAN.md" —
    # bare names, which the agent resolves against its working directory. In the split
    # layout that directory is the common parent of the two repositories and holds
    # neither file, so every task opened by reading two paths that do not exist and then
    # spent turns hunting for them. Naming the full path costs one line and removes the
    # hunt; it also keeps a same-named file in the working directory from winning.
    $whereLines = New-Object System.Collections.Generic.List[string]
    if (Test-Path $Config.plan) { $whereLines.Add("  $planName is at $($Config.plan)") }
    $whereLines.Add("  $promptsName is at $($Config.prompts)")
    $whereLines.Add("  the code repository is $($Config.codeDir)")
    $where = "Paths, because your working directory is not where these files live:`n" +
             ($whereLines -join "`n") + "`n`n"

    if (-not $block) {
        # No block for this phase: fall back to pointing at the file. Say so loudly,
        # because a missing block is usually a typo in the phase id, not a design choice.
        Write-Host "No '## Phase $Phase' block in $promptsName — falling back to a pointer prompt." -ForegroundColor Yellow
        return $where + "Read $planName and $promptsName, then carry out the Phase $Phase prompt from $promptsName exactly as it is written there, including its CHECK FIRST step. Do not go beyond that phase."
    }

    $what = if ($isTask) { "task $Phase" } else { "phase $Phase" }
    # The last task in this workflow deletes the plan, so by the time it runs there is no
    # plan to name. Naming one anyway sends the agent looking for a file that is not there.
    $of = if (Test-Path $Config.plan) { " of $planName" } else { '' }
    $header = "You are executing $what$of, unattended, in a headless session.`n" +
              "The instructions below are the prompt for it, copied verbatim from $promptsName.`n" +
              "Follow them exactly. Do not go beyond what they ask for.`n`n"

    return $header + $where + $block
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
# ---------------------------------------------------------------------------
# Telling the person
# ---------------------------------------------------------------------------

function ConvertTo-AppleScriptLiteral {
    <#
        Escapes a string for use inside a double-quoted AppleScript literal, which is
        source code by the time `osascript -e` sees it. A backslash must be doubled first,
        or the backslash added in front of a quote would itself be escaped by a backslash
        that was already there.
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

    # .Replace, not -replace: its arguments are literal strings, so there is no second
    # escaping layer to reason about. A backslash written as a regex would have to be
    # doubled on the pattern side and not on the replacement side, which is exactly the
    # asymmetry that makes this kind of code wrong on the first try.
    return $Text.Replace('\', '\\').Replace('"', '\"')
}

function Send-PhaseKitNotice {
    <#
        Sound and a desktop notice, for the two moments that are worth interrupting
        someone: the sequence finished, or it stopped and needs an answer.

        The second is the one that pays for this. A stopped sequence costs nothing to fix
        and everything to not notice - the run that waited three hours for a person to
        walk past a terminal is the most expensive thing this tool can do.

        Sound first and separately from the notice: a notification can be suppressed by
        do-not-disturb or a full-screen window, and neither is a reason to fail silently.
        Every part is best-effort on every platform - a machine with no audio device, no
        notification daemon, or no desktop at all must not take a run down. The terminal
        bell is the last resort, and it is the one that works over ssh, which is where an
        unattended run often actually lives.
    #>
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('done', 'attention')] [string] $Kind = 'done'
    )

    $bell = { foreach ($i in 1..3) { [Console]::Out.Write("`a"); Start-Sleep -Milliseconds 800 } }

    try {
        if ($IsWindows) {
            foreach ($i in 1..3) {
                if ($Kind -eq 'attention') { [System.Media.SystemSounds]::Exclamation.Play() }
                else { [System.Media.SystemSounds]::Asterisk.Play() }
                Start-Sleep -Milliseconds 800
            }
        } elseif ($IsMacOS -and (Get-Command afplay -ErrorAction SilentlyContinue)) {
            $sound = if ($Kind -eq 'attention') { '/System/Library/Sounds/Sosumi.aiff' }
                     else { '/System/Library/Sounds/Glass.aiff' }
            foreach ($i in 1..3) { & afplay $sound 2>$null; Start-Sleep -Milliseconds 200 }
        } else {
            & $bell
        }
    } catch { try { & $bell } catch { } }

    try {
        if ($IsWindows) {
            Add-Type -AssemblyName System.Windows.Forms
            Add-Type -AssemblyName System.Drawing
            $tray = New-Object System.Windows.Forms.NotifyIcon
            $tray.Icon = [System.Drawing.SystemIcons]::Information
            $tray.Visible = $true
            $tray.BalloonTipTitle = $Title
            $tray.BalloonTipText = $Message
            $tray.BalloonTipIcon = if ($Kind -eq 'attention') { 'Warning' } else { 'Info' }
            $tray.ShowBalloonTip(30000)
            # The notice is drawn by this process; disposing immediately takes it away again.
            Start-Sleep -Seconds 12
            $tray.Visible = $false
            $tray.Dispose()
        } elseif ($IsMacOS -and (Get-Command osascript -ErrorAction SilentlyContinue)) {
            # Both strings reach AppleScript as source, so an unescaped quote in a stop
            # reason would close the literal and the rest would be read as code.
            & osascript -e "display notification `"$(ConvertTo-AppleScriptLiteral $Message)`" with title `"$(ConvertTo-AppleScriptLiteral $Title)`"" 2>$null
        } elseif (Get-Command notify-send -ErrorAction SilentlyContinue) {
            # notify-send takes its arguments as arguments, so nothing needs escaping - but
            # a leading dash would be read as an option, hence --.
            $urgency = if ($Kind -eq 'attention') { 'critical' } else { 'normal' }
            & notify-send --urgency=$urgency --expire-time=30000 -- $Title $Message 2>$null
        }
    } catch { }
}

# ---------------------------------------------------------------------------
# Waiting out a usage limit
# ---------------------------------------------------------------------------

$script:AwakeDepth = 0

function Set-MachineAwake {
    <#
        Keeps the machine from suspending for as long as an unattended run is in flight.

        A sequence that waits three hours for a usage limit is exactly the workload an
        operating system decides is idle, and a suspended machine runs nothing. The
        display is deliberately left alone everywhere: this asks the system to stay up,
        not the screen to stay on. Nested callers are counted, so a run inside a sequence
        releasing the request does not let the machine sleep under the rest of it.

        Each platform has its own mechanism and none of them is required. A machine that
        offers no way to ask is not a reason to fail: the run proceeds, and sleeps if the
        power settings say so. Say so once rather than silently, so nobody is surprised
        by a wait that died overnight.
    #>
    param([switch] $Off)

    if ($Off) {
        $script:AwakeDepth = [Math]::Max(0, $script:AwakeDepth - 1)
        if ($script:AwakeDepth -gt 0) { return }

        if ($IsWindows) {
            try { [void][PhaseKit.Power]::SetThreadExecutionState([uint32] '0x80000000') } catch { }
        } elseif ($script:AwakeProcess) {
            # macOS and Linux hold the request in a child process; ending it releases it.
            try { Stop-Process -Id $script:AwakeProcess -Force -ErrorAction Stop } catch { }
            $script:AwakeProcess = $null
        }
        return
    }

    $script:AwakeDepth++
    if ($script:AwakeDepth -gt 1) { return }

    if ($IsWindows) {
        try {
            if (-not ('PhaseKit.Power' -as [type])) {
                Add-Type -Namespace PhaseKit -Name Power -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
            }
            $ES_CONTINUOUS = [uint32] '0x80000000'
            $ES_SYSTEM_REQUIRED = [uint32] '0x00000001'
            [void][PhaseKit.Power]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED)
        } catch {
            Write-Host '  Could not ask Windows to stay awake - a long wait may be cut short by sleep.' -ForegroundColor DarkYellow
        }
        return
    }

    # `caffeinate -s` and `systemd-inhibit` both hold the request for as long as the
    # process they wrap lives, so the idle child process IS the request. Both are asked
    # for the system and not the display, matching what the Windows flag does.
    $holder = if ($IsMacOS) {
        @{ exe = 'caffeinate'; args = @('-s', '-w', $PID) }
    } elseif ($IsLinux) {
        @{ exe = 'systemd-inhibit'; args = @('--what=idle:sleep', '--who=phasekit',
                                             '--why=unattended run', '--mode=block',
                                             'sleep', 'infinity') }
    } else { $null }

    if (-not $holder -or -not (Get-Command $holder.exe -ErrorAction SilentlyContinue)) {
        if (-not $script:AwakeWarned) {
            $what = if ($holder) { "$($holder.exe) is not installed" } else { 'this platform offers no way to ask' }
            Write-Host "  Cannot keep the machine awake ($what). A long wait may be cut short by sleep." -ForegroundColor DarkYellow
            $script:AwakeWarned = $true
        }
        return
    }

    try {
        # No -WindowStyle: this branch only ever runs off Windows, where Start-Process
        # rejects that parameter outright rather than ignoring it.
        $p = Start-Process -FilePath $holder.exe -ArgumentList $holder.args -PassThru -ErrorAction Stop
        $script:AwakeProcess = $p.Id
    } catch {
        Write-Host "  $($holder.exe) would not start - a long wait may be cut short by sleep." -ForegroundColor DarkYellow
    }
}

function Wait-UntilDeadline {
    <#
        Sleeps until a wall-clock time, not for a duration.

        `Start-Sleep -Seconds 10000` measures a timer that a suspended machine does not
        advance and does not reliably fire on resume: a run that slept through a standby
        woke up hours late, or not at all. Short sleeps against `Get-Date` cannot drift
        that way — whatever happens to the machine in between, the first tick after the
        deadline ends the wait.

        The countdown is written to the run log as well as the console, because a wait is
        otherwise indistinguishable from a dead run: no claude process, and a log that
        stopped growing. That misreading is the most expensive one in this workflow.
    #>
    param(
        [Parameter(Mandatory)] [datetime] $Deadline,
        [string] $LogPath
    )

    $lastNote = Get-Date
    while ($true) {
        $left = ($Deadline - (Get-Date)).TotalSeconds
        if ($left -le 0) { break }

        if (((Get-Date) - $lastNote).TotalMinutes -ge 15) {
            $note = "$script:NoteMarker ... still waiting out the usage limit, {0:N0} min to go (resuming ~{1})" -f ($left / 60), $Deadline.ToString('HH:mm')
            Write-Host $note -ForegroundColor DarkGray
            if ($LogPath) { Add-Content -LiteralPath $LogPath -Value $note }
            $lastNote = Get-Date
        }

        Start-Sleep -Seconds ([Math]::Min(60, [Math]::Max(1, [int] $left)))
    }
}

$script:LimitPattern = 'usage limit|session limit|weekly limit|rate limit|resets at|resets \d|\b429\b'

# phasekit writes its own notes into the agent's log so `logs -Follow` shows a run that
# is waiting rather than a log that simply stopped. Those notes say "usage limit" — so
# they must be recognisable, or the next retry reads the previous retry's note and
# confirms itself: eight waits, four hours, on the strength of nothing but its own voice.
$script:NoteMarker = '[phasekit]'

# A dropped link is not a spent allowance and not a question to the owner: it is the one
# failure worth retrying at once. Kept narrow on purpose — anything not listed here still
# stops the run and is shown, because a sequence that retries an unknown failure eight
# times hides it eight times.
$script:TransientPattern = 'Connection closed mid-response|connection error|ECONNRESET|ETIMEDOUT|EPIPE|socket hang up|Overloaded|\b(502|503|504|529)\b|Internal server error'

function Get-LimitSignal {
    <#
        The log is JSONL, and most of its bulk is tool results — whatever the agent read,
        grepped or printed. Matching the limit pattern against that raw text asks a file
        the agent happened to open whether the account is out of allowance. It once said
        yes: a grep of docs/audit.md scrolled past a `429` and a crashed run
        ("Connection closed mid-response") was filed as a usage limit and slept half an
        hour before resuming.

        So match only against text that speaks for the runtime, never for the workload:
        lines the CLI wrote outside the JSON stream (its own limit banner lands here),
        the `result` field of a result record, and assistant prose. Tool results, tool
        inputs and thinking blocks are excluded — that is where quoted numbers live.
    #>
    param([Parameter(Mandatory)] [string] $LogTail)

    $parts = [System.Collections.Generic.List[string]]::new()

    foreach ($line in ($LogTail -split "`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }

        # phasekit's own notes are not evidence about the account — skip them first.
        if ($trimmed.StartsWith($script:NoteMarker)) { continue }

        # Not JSON: the CLI's own stderr, where its limit banner lands.
        if (-not $trimmed.StartsWith('{')) { $parts.Add($trimmed); continue }

        try { $d = $trimmed | ConvertFrom-Json } catch { $parts.Add($trimmed); continue }

        switch ($d.type) {
            'result' {
                if ($d.result) { $parts.Add([string] $d.result) }
            }
            'assistant' {
                foreach ($c in $d.message.content) {
                    if ($c.type -eq 'text' -and $c.text) { $parts.Add([string] $c.text) }
                }
            }
        }
    }

    return ($parts -join "`n")
}

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
because a task can be half-done with edits on disk and no commit. Then finish the target
you were interrupted on, under the same rules, and nothing beyond it. Do not redo work
that is already committed.

Stop as soon as that target is committed and its ledger box is ticked. Do not start the
next target, and do not create a branch for it: the runner merges this branch into the
main branch before the next target begins, and a branch stacked on one that has not been
merged yet leaves the runner verifying a branch it is no longer on, which stops the
sequence and needs a person.
'@

function Write-StreamLine {
    <#
        Renders one stream-json line as a readable line of terminal output. Shared by the
        live run and by `phasekit logs`, because a log full of raw JSON is not a log — it
        is the reason you go and look at git instead.

        When replaying, the event's own timestamp is used, so a log reads as history
        rather than as everything having happened just now.
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Line,
        [string] $SessionFile
    )

    if ($Line -notmatch '^\s*\{') {
        if ($Line.Trim()) { Write-Host $Line }
        return
    }

    try { $ev = $Line | ConvertFrom-Json } catch { return }

    $t = if ($ev.timestamp) {
        try { ([datetime] $ev.timestamp).ToLocalTime().ToString('HH:mm:ss') } catch { (Get-Date).ToString('HH:mm:ss') }
    } else { (Get-Date).ToString('HH:mm:ss') }

    if ($SessionFile -and $ev.session_id -and $ev.session_id -ne $script:SessionId) {
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
        Write-StreamLine -Line $line -SessionFile $SessionFile
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
        $signal = Get-LimitSignal -LogTail $tail

        $isLimit = $signal -match $script:LimitPattern
        $isTransient = -not $isLimit -and $signal -match $script:TransientPattern

        if (-not $isLimit -and -not $isTransient) {
            Write-Host ''
            Write-Host "Stopped for a reason that is neither a usage limit nor a dropped connection (exit $exit)." -ForegroundColor Red
            Write-Host 'Last lines of the log — an agent that stops to ask a question looks like this too:' -ForegroundColor Red
            Write-Host $(if ($signal) { $signal } else { $tail })
            Write-Host ''
            Write-Host "Full log: $LogPath" -ForegroundColor Red
            Write-Host "Answer it without losing its context:  phasekit reply $Phase -Text `"your answer`"" -ForegroundColor Cyan
            return $exit
        }

        $attempt++

        if ($isTransient) {
            # The link dropped, not the allowance. Waiting out a usage-limit interval here
            # would idle half an hour over a fault that is usually gone in seconds, and
            # stopping would hand an unattended sequence back to someone who is asleep.
            # Back off briefly and resume: the session id is pinned, so nothing is re-done.
            $wait = [Math]::Min(5, $attempt)
            $resumeAt = (Get-Date).AddMinutes($wait).ToString('HH:mm')
            $note = "$script:NoteMarker Connection dropped. Waiting $wait min, resuming at ~$resumeAt (attempt $attempt of $($Config.maxRetries))."
        }
        else {
            $announced = Get-ResetWaitMinutes -LogTail $signal
            $wait = if ($announced) { $announced } else { $Config.waitMinutes }
            $source = if ($announced) { 'until the announced reset' } else { 'fixed interval' }
            $resumeAt = (Get-Date).AddMinutes($wait).ToString('HH:mm')
            $note = "$script:NoteMarker Usage limit reached. Waiting $wait min ($source), resuming at ~$resumeAt (attempt $attempt of $($Config.maxRetries))."
        }
        Write-Host ''
        Write-Host $note -ForegroundColor Yellow
        # Into the log too, so `phasekit logs -Follow` shows a run that is waiting rather
        # than a log that simply stopped.
        Add-Content -LiteralPath $LogPath -Value ''
        Add-Content -LiteralPath $LogPath -Value $note

        Set-MachineAwake
        try { Wait-UntilDeadline -Deadline (Get-Date).AddMinutes($wait) -LogPath $LogPath }
        finally { Set-MachineAwake -Off }

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

function Invoke-GitPushWithRetry {
    <#
        A push during an unattended run, retried when the failure is the network
        and refused immediately when it is a decision.

        The two are not the same thing and must not share an outcome. A dropped
        connection or a momentarily unreachable host is worth another attempt in
        fifteen seconds; it cost an entire 32-target sequence once, stopped at the
        first task with "push failed" while the very next `git push` by hand
        succeeded. A rejected push is the opposite: the remote has moved, or the
        branch is protected, or the credentials are gone. Retrying that is at best
        noise and at worst the beginning of an argument with a diverged remote
        that only a person should settle — so it stops on the first answer.

        Returns the exit code as the ONLY thing written to the output stream:
        everything the user reads goes through Write-Host. Read it at the call
        site as @(Invoke-GitPushWithRetry ...)[-1], the way the merge result is.
    #>
    param(
        [Parameter(Mandatory)] [string] $RepoDir,
        [int] $MaxAttempts = 4
    )

    # Everything here is a decision, a misconfiguration or a missing credential:
    # the second attempt fails exactly like the first, so a retry only delays the
    # report. "Could not resolve host" is deliberately NOT in this list — a name
    # that will not resolve now often resolves a minute later, which is the whole
    # case this retry exists for.
    $refused = 'rejected|non-fast-forward|fetch first|protected branch|pre-receive hook declined|' +
               'Permission denied|Authentication failed|could not read Username|' +
               'has no upstream branch|No configured push destination|src refspec|Repository not found|' +
               'does not appear to be a git repository'

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $out = (git -C $RepoDir push 2>&1 | Out-String)
        $code = $LASTEXITCODE
        if ($out.Trim()) { Write-Host $out.TrimEnd() }
        if ($code -eq 0) { return 0 }

        if ($out -match $refused) {
            Write-Host '  The remote refused the push. Not retrying: this needs a person.' -ForegroundColor Yellow
            return $code
        }
        if ($attempt -eq $MaxAttempts) {
            Write-Host ("  Push failed {0} times; giving up." -f $MaxAttempts) -ForegroundColor Yellow
            return $code
        }

        $wait = 15 * $attempt
        Write-Host ("  Push failed (attempt {0} of {1}) and the reason looks transient; retrying in {2}s." `
                    -f $attempt, $MaxAttempts, $wait) -ForegroundColor Yellow
        Start-Sleep -Seconds $wait
    }
    return 1
}

function Get-NotesRepo {
    <#
        The working repository, when it is a different one from the code repository — the
        plan-in-a-separate-notes-repo layout. Returns $null when they are the same repo,
        or when workingDir is not a repo at all.

        It matters because a phase's work does not have to land in the code repository. A
        documentation task can be entirely a notes-repo task, and measuring it by commits
        on the code branch reports a success as "the branch has no commits on it".
    #>
    param([Parameter(Mandatory)] $Config)

    $root = { param($d)
        if (-not $d -or -not (Test-Path $d)) { return $null }
        $r = git -C $d rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $r) { return $null }
        return (Resolve-Path $r.Trim()).Path
    }

    # Anchored on the plan, not on workingDir. In the split layout workingDir is the
    # *common parent* of the two checkouts and is typically not a repository at all, while
    # the plan is by definition inside the notes repo — so this is both the correct
    # question and the one that has an answer.
    $notes = & $root (Split-Path -Parent $Config.plan)
    $code = & $root $Config.codeDir
    if (-not $notes -or $notes -eq $code) { return $null }
    return $notes
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
        [Parameter(Mandatory)] [string] $Phase,

        # For a target whose whole job is outside both repositories — retiring a
        # repository on the host, say. Producing no commit is then the expected outcome,
        # and only a target that says so in the config gets the exemption.
        [switch] $AllowNoCommits
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

    # No commits on the branch is usually a phase that produced nothing. It is not, when
    # the plan lives in its own repository and the task was entirely a notes task: the
    # work is real, it is just not in the code repository. Look there before calling it a
    # failure, using the second line of the .base file — the notes HEAD as it was when the
    # run started. Without that line (a run from before this existed) the old reading
    # stands, because an unmeasurable claim is not evidence.
    $notesCommits = @()
    if ($commits.Count -eq 0) {
        $notes = Get-NotesRepo -Config $Config
        $notesBase = if (Test-Path $baseFile) { @(Get-Content -LiteralPath $baseFile)[1] }
        if ($notes -and $notesBase) {
            $notesCommits = @(git -C $notes log --oneline "$($notesBase.Trim())..HEAD" 2>$null)
        }
        if ($notesCommits.Count -eq 0 -and -not $AllowNoCommits) { $problems.Add('the branch has no commits on it') }
    }

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
        ok           = ($problems.Count -eq 0)
        branch       = $branch
        base         = $base
        commits      = $commits
        notesCommits = $notesCommits
        problems     = $problems
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

# ---------------------------------------------------------------------------
# Unattended sequences
# ---------------------------------------------------------------------------

function Get-AutoSequence {
    <#
        The list of targets `phasekit auto` walks, read from phasekit.json:

            "autoSequence": [
              "4.2",
              { "target": "4.3", "model": "opus" },
              { "target": "6.1", "note": "needs an API key you must obtain yourself" }
            ]

        A bare string uses the configured default model. An object may override the model
        per target, which is where the cheap-model-for-mechanical-work decision lives.
    #>
    param([Parameter(Mandatory)] $Config, [string[]] $Targets)

    if ($Targets) {
        # Accept both -Targets 4.2,4.3 and -Targets "4.2,4.3", since the second is what
        # survives being forwarded to a detached child process.
        $flat = @()
        foreach ($t in $Targets) { $flat += ($t -split ',' | Where-Object { $_.Trim() }) }

        # Naming a target on the command line says *which* to run, not that everything the
        # config knows about it should be forgotten. Its model, its note and its
        # allowNoCommits flag still apply.
        $configured = @{}
        foreach ($e in @($Config.autoSequence)) {
            if ($e -is [string]) { $configured[$e] = [pscustomobject]@{ target = $e; model = $null; note = $null; allowNoCommits = $false } }
            elseif ($e.target)   { $configured[$e.target] = [pscustomobject]@{ target = $e.target; model = $e.model; note = $e.note; allowNoCommits = [bool]$e.allowNoCommits } }
        }

        return @($flat | ForEach-Object {
            $name = $_.Trim()
            if ($configured.ContainsKey($name)) { $configured[$name] }
            else { [pscustomobject]@{ target = $name; model = $null; note = $null; allowNoCommits = $false } }
        })
    }

    if (-not $Config.autoSequence -or $Config.autoSequence.Count -eq 0) {
        throw 'Nothing to run. Add "autoSequence" to phasekit.json, or pass -Targets 4.2,4.3'
    }

    $i = -1
    return @($Config.autoSequence | ForEach-Object {
        $i++
        if ($_ -is [string]) { [pscustomobject]@{ target = $_; model = $null; note = $null; allowNoCommits = $false } }
        else {
            # Say which entry is wrong and what it is missing. Without this the run
            # walks on with an empty target and dies several frames later on
            # "Cannot bind argument to parameter 'Target'", which names neither the
            # file nor the entry — a config typo reported as an internal error.
            if (-not $_.target) {
                $keys = @($_.PSObject.Properties.Name) -join ', '
                throw ("autoSequence entry $i has no `"target`". It has: $keys. " +
                       'Each entry is either a bare string ("4.2") or an object with a ' +
                       '"target" key ({ "target": "4.2", "note": "..." }).')
            }
            [pscustomobject]@{ target = $_.target; model = $_.model; note = $_.note; allowNoCommits = [bool]$_.allowNoCommits }
        }
    })
}

function Test-TargetDone {
    <#
        Whether a target has already landed, so a rerun of the sequence picks up where it
        stopped instead of redoing finished work. Done means both halves agree: every
        ledger box for it is ticked, AND its branch is either gone or already contained in
        the main branch. One without the other is the ledger-versus-repository
        disagreement this whole tool exists to surface, so it counts as not done.
    #>
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] [string] $Target)

    $escaped = [regex]::Escape($Target)
    $boxes = @()
    $hasPlan = Test-Path $Config.plan
    if ($hasPlan) {
        foreach ($line in Get-Content -LiteralPath $Config.plan) {
            # "4.2" matches its own box; a phase like "4" matches every 4.x box.
            if ($line -match "^\s*- \[( |x)\]\s+$escaped(\.|\s)") { $boxes += $Matches[1] }
        }
    }

    # No plan file at all is not the same as an unticked box. A plan is deleted once it is
    # finished — that is the last task in this very workflow — and reading its absence as
    # "nothing has been done" would have `auto` redo the entire refactor from the first
    # target. With no ledger there is no ledger-versus-repository disagreement to catch,
    # so the repository alone decides.
    if ($hasPlan) {
        if ($boxes.Count -eq 0) { return $false }
        if ($boxes -contains ' ') { return $false }
    }

    $branch = "$($Config.branchPrefix)$Target"
    if (-not (git -C $Config.codeDir rev-parse --verify --quiet $branch)) {
        # With a ledger, a missing branch means merged and tidied away — the tick is the
        # evidence and the branch was only ever a working area. With no ledger there is no
        # evidence at all, and a target that was never started looks exactly the same. So
        # the two cases part here: no plan, no branch, not done. Redoing finished work
        # wastes a session; skipping unfinished work builds everything after it on sand.
        return $hasPlan
    }

    $main = Get-MainBranch -Config $Config
    git -C $Config.codeDir merge-base --is-ancestor $branch $main 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Test-TransientFailure {
    <#
        Whether a non-zero exit was the network rather than the work. A dropped stream or a
        5xx is worth retrying blindly; an agent that stopped to ask a question is not, and
        retrying that one just burns turns re-asking it.
    #>
    param([Parameter(Mandatory)] [string] $LogTail)
    return ($LogTail -match '(?i)api error|stalled mid-stream|connection (reset|closed|error)|ECONNRESET|ETIMEDOUT|socket hang up|502|503|504|overloaded')
}
