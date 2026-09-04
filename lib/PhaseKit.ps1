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
        # How many times one target may be picked up in a fresh conversation after its
        # context window filled. Small on purpose: see Invoke-AgentWithLimitRetry.
        maxContextRestarts = 2
        # Where the conversation is compacted, in tokens. Left to the CLI's own default a
        # long task grows its context monotonically - one measured target reached 542k and
        # spent its last 174 requests above 460k. Nothing in that tail was harder than the
        # work at the start; it was just carrying every earlier turn again, and a request
        # costs what its context costs. Compacting at a ceiling turns that curve into a
        # sawtooth. Set 'auto' to hand the decision back to the CLI.
        autoCompact      = 200000
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
        if ($null -ne $raw.usageLimit.maxContextRestarts) {
            $cfg.maxContextRestarts = [int] $raw.usageLimit.maxContextRestarts
        }
    }
    if ($raw.PSObject.Properties.Name -contains 'autoCompact' -and $raw.autoCompact) {
        $cfg.autoCompact = $raw.autoCompact
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

function Get-PlanSectionText {
    <#
        One target's own section of the plan, headline included, as the prompt can quote
        it verbatim.

        This exists because of what a prompt saying "read PLAN.md" actually costs. The
        plan for a real cycle is 126 KB; reading it spends about 16k tokens, and unlike a
        one-off cost it then sits in the context of every request the session goes on to
        make. Over a long target that is several million tokens re-read to hold a document
        the agent needed four hundred words of. The section is quoted instead, and the
        file stays there for the rare task that genuinely needs its neighbours.
    #>
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $Phase
    )

    if (-not (Test-Path $Config.plan)) { return '' }
    $outline = Get-PlanOutline -PlanLines (Get-Content -LiteralPath $Config.plan)
    if (-not $outline.targets.ContainsKey($Phase)) { return '' }

    $t = $outline.targets[$Phase]
    $head = if ($t.title) { "### $Phase - $($t.title)" } else { "### $Phase" }
    return (@($head) + @($t.body)) -join "`n"
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

    # {{SECTION}} is opt-in: a prompt that does not use it keeps whatever it says today.
    # String.Replace, not -replace, because the plan is prose and a '$' in it would be
    # read as a capture-group reference and vanish.
    if ($block -match '\{\{SECTION\}\}') {
        $section = Get-PlanSectionText -Config $Config -Phase $Phase
        if ($section) {
            $block = $block.Replace('{{SECTION}}', $section)
        }
        else {
            Write-Host "No section for $Phase in $planName - the prompt will point at the file instead." -ForegroundColor Yellow
            $block = $block.Replace('{{SECTION}}', "(Not found in $planName. Read the file and find $Phase yourself.)")
        }
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

# A conversation that outgrows its window is a third kind of ending, and it is the one
# that used to stop an unattended sequence dead. It is neither a spent allowance nor a
# dropped link: waiting changes nothing, and resuming makes it worse, because --resume
# replays the very transcript that overflowed and overflows again on the first turn.
#
# The recovery is the opposite of a resume - a NEW conversation, given the continue
# prompt, which is written to re-establish reality from the gates and the git log rather
# than from a memory it no longer has. Nothing is lost by that, because the branch, the
# commits and the ledger are on disk: the transcript was never where the progress lived.
#
# Matched only against text the runtime wrote, never against the agent's own prose. An
# agent that remarks it is "running low on context" is describing its situation, not
# ending, and restarting it on the strength of that would throw away a session that was
# still working.
$script:ContextPattern = 'prompt is too long|input length and .{0,16}max_tokens.{0,16} exceed|exceeds? (?:the )?(?:maximum )?context (?:window|limit|length)|context_length_exceeded|context length exceeded|conversation is too long|compaction failed|failed to compact'

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

        -RuntimeOnly drops the assistant's prose as well, leaving only what the CLI and
        the API said. Some verdicts must not be reachable by anything the agent can type:
        a context restart throws a live conversation away, so it is decided on the
        runtime's word alone.
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $LogTail,
        [switch] $RuntimeOnly
    )

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
                if ($RuntimeOnly) { break }
                foreach ($c in $d.message.content) {
                    if ($c.type -eq 'text' -and $c.text) { $parts.Add([string] $c.text) }
                }
            }
        }
    }

    return ($parts -join "`n")
}

function Get-StopReason {
    <#
        Why the agent stopped, in one word, read from the tail of its own log. The retry
        loop and the tests both call this, so what the tests assert is what actually runs.

            limit      the subscription allowance ran out. Wait it out and resume the
                       same conversation - nothing is lost, the work is mid-thought
            transient  the link dropped. Back off briefly and resume
            context    the conversation outgrew its window. A resume would replay the
                       transcript that overflowed, so the same target is picked up in a
                       fresh conversation instead
            stop       everything else, including the agent stopping to ask a question -
                       which from the outside looks exactly like a failure, and must
                       reach a person rather than be retried into silence

        The order is not arbitrary. Context is decided first because "the context limit"
        contains the word limit: read as a spent allowance it would sleep for half an
        hour and then resume straight back into the same overflow.
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $LogTail)

    if ((Get-LimitSignal -LogTail $LogTail -RuntimeOnly) -match $script:ContextPattern) { return 'context' }

    $signal = Get-LimitSignal -LogTail $LogTail
    if ($signal -match $script:LimitPattern) { return 'limit' }
    if ($signal -match $script:TransientPattern) { return 'transient' }
    return 'stop'
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

        Three endings are recovered from, and each one needs a different move -
        Get-StopReason names them. The awkward one is a full context window: it is the
        only case where resuming is worse than starting over, because the resume replays
        the transcript that overflowed. There the same target is picked up in a fresh
        conversation, which is safe precisely because phasekit keeps progress in the
        branch, the commits and the ledger rather than in the transcript.
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
    $restarts = 0
    while ($exit -ne 0 -and $attempt -lt $Config.maxRetries) {

        # -Tail and -Raw are mutually exclusive on Get-Content, so join the lines by hand.
        $tail = if (Test-Path $LogPath) { (Get-Content -LiteralPath $LogPath -Tail 40) -join "`n" } else { '' }
        $signal = Get-LimitSignal -LogTail $tail
        $reason = Get-StopReason -LogTail $tail

        # A restart that overflows again is not a recovery, it is a loop that spends the
        # whole allowance re-reading the same plan. Two restarts cover a target that
        # genuinely needs more than one window; a third means the target is too big to be
        # done this way, and resizing it is a person's decision, not a retry's.
        if ($reason -eq 'context' -and $restarts -ge $Config.maxContextRestarts) {
            Write-Host ''
            Write-Host "The conversation outgrew its context window $restarts times on this target." -ForegroundColor Red
            Write-Host 'Starting it again would spend the allowance re-reading the same plan.' -ForegroundColor Red
            Write-Host 'Split the target, or narrow what it has to read, then run it again.' -ForegroundColor Red
            Write-Host ''
            Write-Host "Full log: $LogPath" -ForegroundColor Red
            return $exit
        }

        if ($reason -eq 'stop') {
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

        if ($reason -eq 'context') {
            # Not a resume. --resume replays the transcript that overflowed, so it would
            # fail again on the first turn and burn a retry doing it. A fresh conversation
            # with the continue prompt reads the ledger, the gates and the git log, which
            # is where the progress actually is.
            $restarts++
            $note = "$script:NoteMarker Context window full. Picking the same target up in a fresh " +
                    "conversation (restart $restarts of $($Config.maxContextRestarts)) - the branch, " +
                    'the commits and the ledger carry what was done.'
            Write-Host ''
            Write-Host $note -ForegroundColor Yellow
            Add-Content -LiteralPath $LogPath -Value ''
            Add-Content -LiteralPath $LogPath -Value $note

            # Clearing the pinned id makes the stream reader record the new conversation's
            # id the moment it arrives, so a later `phasekit reply` reaches the live one
            # rather than the transcript that was abandoned.
            $script:SessionId = $null
            $exit = Invoke-Agent -ClaudeArgs (@('-p', $script:ContinuePrompt) + $Common) `
                -LogPath $LogPath -SessionFile $SessionFile
            continue
        }

        if ($reason -eq 'transient') {
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
              { "target": "4.4", "effort": "medium" },
              { "target": "6.1", "note": "needs an API key you must obtain yourself" }
            ]

        A bare string uses the configured defaults. An object may override the model or
        the effort per target, which is where the cheap-work-for-mechanical-work decision
        lives.

        The two are not the same lever, and the difference matters on a product one
        person will read end to end. A different model writes differently: on a
        mechanical task nobody minds, but across half a codebase it reads as two authors.
        The same model at lower effort thinks less about the same problem and still
        writes in one voice — so effort is the safer of the two wherever the output is
        code somebody will later copy the style of.
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
            if ($e -is [string]) { $configured[$e] = [pscustomobject]@{ target = $e; model = $null; effort = $null; note = $null; allowNoCommits = $false } }
            elseif ($e.target)   { $configured[$e.target] = [pscustomobject]@{ target = $e.target; model = $e.model; effort = $e.effort; note = $e.note; allowNoCommits = [bool]$e.allowNoCommits } }
        }

        return @($flat | ForEach-Object {
            $name = $_.Trim()
            if ($configured.ContainsKey($name)) { $configured[$name] }
            else { [pscustomobject]@{ target = $name; model = $null; effort = $null; note = $null; allowNoCommits = $false } }
        })
    }

    if (-not $Config.autoSequence -or $Config.autoSequence.Count -eq 0) {
        throw 'Nothing to run. Add "autoSequence" to phasekit.json, or pass -Targets 4.2,4.3'
    }

    $i = -1
    return @($Config.autoSequence | ForEach-Object {
        $i++
        if ($_ -is [string]) { [pscustomobject]@{ target = $_; model = $null; effort = $null; note = $null; allowNoCommits = $false } }
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
            [pscustomobject]@{ target = $_.target; model = $_.model; effort = $_.effort; note = $_.note; allowNoCommits = [bool]$_.allowNoCommits }
        }
    })
}

function New-RepoSnapshot {
    <#
        One reading of the two things that decide whether a target has landed: the plan's
        ledger, and which branches exist and are already contained in the main branch.

        Asking those questions one target at a time costs three git processes and a file
        read each, which is invisible for a sequence of five and half a minute for a
        sequence of fifty. Taken once and passed around, the same answers cost three
        processes in total.
    #>
    param([Parameter(Mandatory)] $Config)

    $main = Get-MainBranch -Config $Config

    $branches = @{}
    foreach ($b in @(git -C $Config.codeDir for-each-ref --format='%(refname:short)' "refs/heads/$($Config.branchPrefix)*")) {
        if ($b) { $branches[$b.Trim()] = $true }
    }

    $merged = @{}
    foreach ($b in @(git -C $Config.codeDir branch --merged $main --format='%(refname:short)')) {
        if ($b) { $merged[$b.Trim()] = $true }
    }

    # How many commits each unmerged branch is carrying. Only the unmerged ones are
    # asked — usually one or two — because that is the whole question: a branch with
    # commits that has not landed yet is work waiting on its gates, and a dashboard
    # that could not tell it apart from an abandoned one would report every merge as
    # a stall. The gates take longer than the window that decides a run is quiet.
    $ahead = @{}
    foreach ($b in $branches.Keys) {
        if ($merged.ContainsKey($b)) { continue }
        $ahead[$b] = [int] (git -C $Config.codeDir rev-list --count "$main..$b" 2>$null)
    }

    $hasPlan = Test-Path $Config.plan
    $planLines = if ($hasPlan) { @(Get-Content -LiteralPath $Config.plan) } else { @() }

    return [pscustomobject]@{
        main      = $main
        branches  = $branches
        merged    = $merged
        ahead     = $ahead
        hasPlan   = $hasPlan
        planLines = $planLines
    }
}

function Test-TargetDone {
    <#
        Whether a target has already landed, so a rerun of the sequence picks up where it
        stopped instead of redoing finished work. Done means both halves agree: every
        ledger box for it is ticked, AND its branch is either gone or already contained in
        the main branch. One without the other is the ledger-versus-repository
        disagreement this whole tool exists to surface, so it counts as not done.
    #>
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $Target,
        # A reading of the repository and the plan taken once by the caller. Left out, one
        # is taken for this call alone — so every existing caller keeps working and there
        # is still only one set of rules for what "done" means.
        $Snapshot
    )

    if (-not $Snapshot) { $Snapshot = New-RepoSnapshot -Config $Config }

    $escaped = [regex]::Escape($Target)
    $boxes = @()
    $hasPlan = $Snapshot.hasPlan
    foreach ($line in $Snapshot.planLines) {
        # "4.2" matches its own box; a phase like "4" matches every 4.x box.
        if ($line -match "^\s*- \[( |x)\]\s+$escaped(\.|\s)") { $boxes += $Matches[1] }
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
    if (-not $Snapshot.branches.ContainsKey($branch)) {
        # With a ledger, a missing branch means merged and tidied away — the tick is the
        # evidence and the branch was only ever a working area. With no ledger there is no
        # evidence at all, and a target that was never started looks exactly the same. So
        # the two cases part here: no plan, no branch, not done. Redoing finished work
        # wastes a session; skipping unfinished work builds everything after it on sand.
        return $hasPlan
    }

    return $Snapshot.merged.ContainsKey($branch)
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

# ---------------------------------------------------------------------------
# How far along, and how much longer
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Is a runner actually running
# ---------------------------------------------------------------------------

<#
    An unattended sequence has exactly one failure it cannot report: being killed. A run
    that stops writes auto-stopped.txt, sounds the notice and says why. A run that is
    killed - the terminal that launched it closes, the machine is logged out, the process
    tree it happened to be parented to goes away - writes nothing at all, because nothing
    ran to write it. It cost three hours on 2026-09-02: the sequence was waiting out a
    usage limit, the launcher died, and the only reason anybody found out was a dashboard
    reporting the target as quiet.

    So the runner leaves a mark saying which process it is, and anything that reports on
    the sequence can ask that process whether it is alive. Two facts are recorded, not
    one: the pid, and the moment that pid started. Windows hands pids out again, and a
    stale mark whose number now belongs to a browser would report a dead sequence as
    healthy - which is the exact lie this exists to prevent.
#>

function Get-RunnerFile {
    param([Parameter(Mandatory)] $Config)
    return (Join-Path $Config.logDir 'auto-running.json')
}

function Set-RunnerMark {
    <#
        Records this process as the runner, and which target it is on. Called again at
        every target, so a mark left behind by a killed run names the target it died on.
    #>
    param(
        [Parameter(Mandatory)] $Config,
        [string] $Target
    )

    $me = Get-Process -Id $PID
    $mark = [ordered]@{
        pid       = $PID
        # ISO 8601 round-trip: parsed back by the reader, and readable by a person who
        # opens the file to see what is holding the sequence.
        pidStart  = $me.StartTime.ToString('o')
        started   = (Get-Date).ToString('o')
        target    = $Target
        machine   = [System.Net.Dns]::GetHostName()
        config    = $Config.configPath
    }
    $dir = Split-Path -Parent (Get-RunnerFile -Config $Config)
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -LiteralPath (Get-RunnerFile -Config $Config) -Value ($mark | ConvertTo-Json)
}

function Clear-RunnerMark {
    <#
        Removes the mark, but only if it is this process's. A second runner that refused
        to start must not delete the mark belonging to the one it refused to disturb.
    #>
    param([Parameter(Mandatory)] $Config)

    $state = Get-RunnerState -Config $Config
    if ($state -and $state.pid -ne $PID) { return }
    Remove-Item -LiteralPath (Get-RunnerFile -Config $Config) -ErrorAction SilentlyContinue
}

function Get-RunnerState {
    <#
        Who, if anyone, is running this sequence.

            $null    no mark - no sequence has run since the last one finished cleanly
            alive    that process is still there and still is a runner
            dead     the mark is there and the process is not: the run was killed, and
                     nothing else anywhere records that it was

        A mark from another machine is reported as such rather than guessed at: the pid
        means nothing here, and calling it dead would be a claim this machine cannot make.
    #>
    param([Parameter(Mandatory)] $Config)

    $file = Get-RunnerFile -Config $Config
    if (-not (Test-Path $file)) { return $null }

    try { $m = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json } catch { return $null }
    if (-not $m.pid) { return $null }

    $here = ($m.machine -eq [System.Net.Dns]::GetHostName())
    $alive = $false
    if ($here) {
        $proc = Get-Process -Id ([int] $m.pid) -ErrorAction SilentlyContinue
        if ($proc) {
            # The pid alone is not evidence. A recycled pid belonging to something else
            # would report a killed sequence as healthy, so the start time must match too.
            try { $alive = ([datetime] $m.pidStart - $proc.StartTime).Duration().TotalSeconds -lt 2 }
            catch { $alive = $true }
        }
    }

    $started = $null
    try { $started = [datetime] $m.started } catch { }

    return [pscustomobject]@{
        pid     = [int] $m.pid
        target  = [string] $m.target
        started = $started
        machine = [string] $m.machine
        here    = $here
        alive   = $alive
    }
}

function Format-Duration {
    <#
        Minutes as something a person reads at a glance. Anything past a day is quoted in
        days, because "4103m" and "2d 20h" are the same number and only one of them
        answers "do I go to bed".
    #>
    param([AllowNull()] [System.Nullable[double]] $Minutes)

    if ($null -eq $Minutes) { return '--' }
    if ($Minutes -lt 1) { return '<1m' }

    $total = [int] [Math]::Round($Minutes)
    if ($total -lt 60) { return "${total}m" }

    $hours = [int] [Math]::Floor($total / 60)
    $mins = $total % 60
    if ($hours -lt 24) {
        if ($mins -gt 0) { return "${hours}h ${mins}m" }
        return "${hours}h"
    }

    $days = [int] [Math]::Floor($hours / 24)
    $rest = $hours % 24
    if ($rest -gt 0) { return "${days}d ${rest}h" }
    return "${days}d"
}

function Get-Percentile {
    <#
        Linear-interpolated percentile over an unsorted set. The number this tool reports
        as "typical" is a median rather than a mean on purpose: one target that sat out a
        weekend waiting for an allowance to reset would drag a mean far enough that the
        estimate stops meaning anything.
    #>
    param([double[]] $Values, [Parameter(Mandatory)] [double] $P)

    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    if ($sorted.Count -eq 1) { return [double] $sorted[0] }

    $index = ($sorted.Count - 1) * $P
    $low = [int] [Math]::Floor($index)
    $high = [int] [Math]::Ceiling($index)
    if ($low -eq $high) { return [double] $sorted[$low] }
    return [double] ($sorted[$low] + ($sorted[$high] - $sorted[$low]) * ($index - $low))
}

function Get-TargetLogStats {
    <#
        What the log directory knows about each target: how many attempts it took, when it
        was first and last worked on, and how many minutes those attempts spanned.

        A target's cost is the SUM of its attempts, not the span from the first to the
        last. Attempts interleave - a target answered by hand days later still belongs to
        itself - and the span would quietly bill it for every other target's work done in
        between.

        Keyed by the sanitised name the log files carry, which is what New-LogPath writes.
    #>
    param([Parameter(Mandatory)] [string] $LogDir)

    $stats = [ordered]@{}
    if (-not (Test-Path $LogDir)) { return $stats }

    foreach ($file in Get-ChildItem -Path $LogDir -Filter 'phase-*.log' -File -ErrorAction SilentlyContinue) {
        if ($file.Name -notmatch '^phase-(?<target>.+)-(?<stamp>\d{8}-\d{6})\.log$') { continue }

        $name = $Matches['target']
        $start = [datetime]::ParseExact($Matches['stamp'], 'yyyyMMdd-HHmmss', $null)
        # A copied or restored log can carry a write time older than its own name. Clamping
        # keeps one such file from subtracting hours from the estimate.
        $end = if ($file.LastWriteTime -lt $start) { $start } else { $file.LastWriteTime }

        if (-not $stats.Contains($name)) {
            $stats[$name] = [pscustomobject]@{
                target   = $name
                attempts = 0
                minutes  = 0.0
                first    = $start
                last     = $end
                latest   = $start
                latestLog = $file.FullName
            }
        }

        $entry = $stats[$name]
        $entry.attempts++
        $entry.minutes += ($end - $start).TotalMinutes
        if ($start -lt $entry.first) { $entry.first = $start }
        if ($end -gt $entry.last) { $entry.last = $end }
        if ($start -gt $entry.latest) { $entry.latest = $start; $entry.latestLog = $file.FullName }
    }

    return $stats
}

function Get-LogSpend {
    <#
        What one attempt cost, read back from its own log.

        Every request carries its usage, so the log already knows the two numbers that
        decide the bill and nothing else reports: how many requests the target took, and
        how large the context had grown by the end. They multiply. A target that runs four
        hundred requests at half a million tokens of context is not four times a target
        that runs a hundred at two hundred thousand - it is ten.

        Streamed messages repeat their usage across events, so requests are counted by
        request_id and each one is recorded once.

        -TailLines reads only the end of the file, which is all that is needed to answer
        "how big is the context right now" for a run in progress. Parsing a finished 5 MB
        log takes a moment, so `spend` asks for it and the dashboard does not.
    #>
    param(
        [Parameter(Mandatory)] [string] $LogPath,
        [int] $TailLines = 0
    )

    $empty = [pscustomobject]@{ requests = 0; peak = 0; last = 0; read = 0; write = 0; output = 0; weighted = 0 }
    if (-not (Test-Path $LogPath)) { return $empty }

    $lines = if ($TailLines -gt 0) { Get-Content -LiteralPath $LogPath -Tail $TailLines -ErrorAction SilentlyContinue }
             else { Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue }

    $seen = @{}
    $lastCtx = 0
    foreach ($line in $lines) {
        if ($line -notmatch '"request_id"') { continue }
        try { $ev = $line | ConvertFrom-Json } catch { continue }
        if ($ev.type -ne 'assistant') { continue }
        $rid = [string] $ev.request_id
        $u = $ev.message.usage
        if (-not $rid -or -not $u) { continue }
        $rec = [pscustomobject]@{
            ctx   = [int64] $u.input_tokens + [int64] $u.cache_creation_input_tokens + [int64] $u.cache_read_input_tokens
            read  = [int64] $u.cache_read_input_tokens
            write = [int64] $u.cache_creation_input_tokens
            fresh = [int64] $u.input_tokens
            out   = [int64] $u.output_tokens
        }
        $seen[$rid] = $rec
        $lastCtx = $rec.ctx
    }

    if ($seen.Count -eq 0) { return $empty }

    $vals = @($seen.Values)
    $read = ($vals | Measure-Object -Property read -Sum).Sum
    $write = ($vals | Measure-Object -Property write -Sum).Sum
    $fresh = ($vals | Measure-Object -Property fresh -Sum).Sum
    $out = ($vals | Measure-Object -Property out -Sum).Sum
    $peak = ($vals | Measure-Object -Property ctx -Maximum).Maximum

    # One comparable number, in units of a full-price input token: a cached read is a
    # tenth of one, writing the cache is a quarter more, and output is five. The ratios
    # are the published ones and the absolute number is meaningless - what it is for is
    # putting two targets next to each other honestly.
    $weighted = [int64] ($fresh + $read * 0.1 + $write * 1.25 + $out * 5)

    return [pscustomobject]@{
        requests = $seen.Count
        peak     = [int64] $peak
        last     = [int64] $lastCtx
        read     = [int64] $read
        write    = [int64] $write
        output   = [int64] $out
        weighted = $weighted
    }
}

function Get-RunPace {
    <#
        Two honest answers to "how much longer", because there are two clocks and they
        disagree by an order of magnitude.

        `working` is the median target projected over what is left: what a target costs
        when the sequence is actually allowed to run. `observed` is the wall clock since
        the first target started, divided by the targets finished within it: what it has
        really cost, allowance resets, dropped links and sleeping laptops included.
        Quoting only the first is a promise the tool cannot keep; quoting only the second
        hides that most of the wait was never work.
    #>
    param(
        [double[]] $TargetMinutes,
        [AllowNull()] [System.Nullable[double]] $ElapsedMinutes,
        [int] $Finished,
        [int] $Remaining
    )

    $typical = Get-Percentile -Values $TargetMinutes -P 0.5
    $quick = Get-Percentile -Values $TargetMinutes -P 0.25

    $observed = $null
    if ($Finished -gt 0 -and $null -ne $ElapsedMinutes -and $ElapsedMinutes -gt 0) {
        $observed = [double] $ElapsedMinutes / $Finished
    }

    $workingLeft = $null
    if ($null -ne $typical) { $workingLeft = [double] $typical * $Remaining }

    $observedLeft = $null
    if ($null -ne $observed) { $observedLeft = [double] $observed * $Remaining }

    return [pscustomobject]@{
        samples         = @($TargetMinutes).Count
        typicalMinutes  = $typical
        quickMinutes    = $quick
        observedMinutes = $observed
        workingLeft     = $workingLeft
        observedLeft    = $observedLeft
    }
}

function Get-LedgerLabels {
    <#
        The plan's own words for each target, so the dashboard names a target the way its
        author does rather than printing "G.8" twice.
    #>
    param([string[]] $PlanLines)

    $labels = @{}
    foreach ($line in @($PlanLines)) {
        if ($line -match '^\s*- \[( |x)\]\s+(?<target>\S+)\s+(?<label>.+?)\s*$') {
            $key = $Matches['target']
            if (-not $labels.ContainsKey($key)) { $labels[$key] = $Matches['label'] }
        }
    }
    return $labels
}

function Get-PlanOutline {
    <#
        The plan, read as a table of contents: what each phase is for, what each target
        inside it is called, and the sentence its author opened it with.

        The ledger at the bottom of a plan is a list of one-line labels, which is enough
        to draw a progress bar and not enough to answer "what is this cycle actually
        doing". That answer is already written - in the headings and the opening line of
        every section - and until now nothing read it. Nobody should have to open a
        two-thousand-line plan to find out what H.5 was about.

        Parsed, deliberately, from the shape a plan already has rather than from markup
        invented for this: `## <n>. PHASE <key> - <title>` for a phase, `### <target> -
        <title>` for a target. A heading naming several phases at once ("PHASE E and F")
        gives its title to each of them.

        Returns:
            phases    key -> title
            targets   target -> @{ title; summary; line; body }
    #>
    param([string[]] $PlanLines)

    $lines = @($PlanLines)
    $phases = @{}
    $targets = @{}
    $order = [System.Collections.Generic.List[string]]::new()
    $starts = @{}

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        if ($line -match '^##\s+(?:[\w]+\.\s*)?PHASE\s+(?<keys>[^—–-]+?)\s*[—–-]+\s*(?<title>.+?)\s*$') {
            $title = $Matches['title']
            foreach ($key in ($Matches['keys'] -split '(?:\s+and\s+|\s*,\s*|\s*/\s*)')) {
                $k = $key.Trim()
                if ($k) { $phases[$k] = $title }
            }
            continue
        }

        if ($line -match '^###\s+(?<target>[A-Za-z0-9]+\.\d+)\s*[—–-]*\s*(?<title>.*?)\s*$') {
            $t = $Matches['target']
            if (-not $targets.ContainsKey($t)) {
                $targets[$t] = [pscustomobject]@{
                    target  = $t
                    title   = $Matches['title']
                    summary = ''
                    line    = $i
                    body    = @()
                }
                [void] $order.Add($t)
                $starts[$t] = $i
            }
        }
    }

    # A section runs to the next heading of any level. Done in a second pass because the
    # end of one section is only known once the next has been found.
    for ($n = 0; $n -lt $order.Count; $n++) {
        $t = $order[$n]
        $from = $starts[$t] + 1
        $to = $lines.Count - 1
        for ($j = $from; $j -lt $lines.Count; $j++) {
            if ($lines[$j] -match '^#{1,3}\s') { $to = $j - 1; break }
        }
        if ($to -lt $from) { $targets[$t].body = @() }
        else { $targets[$t].body = $lines[$from..$to] }

        # The opening sentence, which in a well-written plan is the one that says why the
        # task exists. The file list and the constraint blocks are answers to other
        # questions, so they are skipped rather than summarised.
        $sentence = ''
        $para = [System.Collections.Generic.List[string]]::new()
        $current = [System.Collections.Generic.List[string]]::new()
        $skip = $false
        foreach ($b in (@($targets[$t].body) + @(''))) {
            $trim = $b.Trim()
            if (-not $trim) {
                # End of a paragraph. A file list or a constraint block answers a
                # different question, so it is dropped whole rather than line by line —
                # reading it line by line is how the tail of a path list became a summary.
                if (-not $skip -and $current.Count -gt 0) { foreach ($c in $current) { $para.Add($c) }; break }
                $current.Clear()
                $skip = $false
                continue
            }
            if ($current.Count -eq 0 -and $trim -match '^(\*\*)?(Files|Vincolo|Constraint|Acceptance|Scope)\b') { $skip = $true }
            # A list, a quote, a table row or a heading - but NOT bold prose. "**This
            # task**" opens half the sections in a well-written plan, and reading its
            # leading asterisks as a bullet skipped exactly the paragraph worth showing.
            if ($current.Count -eq 0 -and $trim -match '^(?:[-+>|#]\s|\*\s|\|)') { $skip = $true }
            $current.Add($trim)
        }
        if ($para.Count -gt 0) {
            $text = ($para -join ' ') -replace '\s+', ' '
            $text = $text -replace '`', '' -replace '\*\*', '' -replace '\*', ''
            # Whole sentences, up to a couple of lines of terminal. Cutting at the first
            # full stop reads badly when a section opens with a four-word one; cutting at
            # a character count reads worse, because it stops mid-clause.
            $sentence = $text
            if ($text.Length -gt 170) {
                $cuts = [regex]::Matches($text.Substring(0, 170), '[.:;]\s')
                $sentence = if ($cuts.Count -gt 0) { $text.Substring(0, $cuts[$cuts.Count - 1].Index + 1) }
                            else { $text.Substring(0, 170) }
            }
        }
        $targets[$t].summary = $sentence
    }

    return [pscustomobject]@{ phases = $phases; targets = $targets }
}

function Get-DashboardFrame {
    <#
        Everything one screen of `phasekit dashboard` shows, read fresh.

        It is derived entirely from the repository, the plan and the log directory. The
        dashboard keeps no state of its own, which is the point: it is honest about a run
        it never saw start, about one that died without saying so, and about work done by
        hand between sequences - none of which a progress file written by the runner would
        have known about.
    #>
    param(
        [Parameter(Mandatory)] $Config,
        [string[]] $Targets,
        # How recently a log must have been written to for the run to count as alive. Long
        # enough to cover a slow gate, short enough that a killed process is not drawn as
        # work in progress.
        [int] $LiveMinutes = 6
    )

    $sequence = Get-AutoSequence -Config $Config -Targets $Targets
    $snapshot = New-RepoSnapshot -Config $Config
    $stats = Get-TargetLogStats -LogDir $Config.logDir
    $labels = Get-LedgerLabels -PlanLines $snapshot.planLines
    $outline = Get-PlanOutline -PlanLines $snapshot.planLines
    $now = Get-Date

    $rows = @()
    foreach ($item in $sequence) {
        $name = $item.target -replace '[^\w.-]', '_'
        $log = if ($stats.Contains($name)) { $stats[$name] } else { $null }
        $done = Test-TargetDone -Config $Config -Target $item.target -Snapshot $snapshot

        $branch = "$($Config.branchPrefix)$($item.target)"
        $carries = if ($snapshot.ahead.ContainsKey($branch)) { $snapshot.ahead[$branch] } else { 0 }

        $state = 'queued'
        if ($done) { $state = 'done' }
        elseif ($log -and ($now - $log.last).TotalMinutes -lt $LiveMinutes) { $state = 'running' }
        elseif ($carries -gt 0) { $state = 'merging' }
        elseif ($log) { $state = 'stalled' }

        # The ledger's own words first: they are the shortest, and they are what the
        # author chose to see in a list. The section heading is the fallback for a target
        # the ledger has not caught up with, which during a cycle is a normal state.
        $label = if ($labels.ContainsKey($item.target)) { $labels[$item.target] }
                 elseif ($outline.targets.ContainsKey($item.target)) { $outline.targets[$item.target].title }
                 else { '' }
        $about = if ($outline.targets.ContainsKey($item.target)) { $outline.targets[$item.target].summary } else { '' }

        # Resolved here rather than in the view, and resolved the same way the runner
        # resolves it: a sequence entry overrides the configured default, and nothing
        # else does. A dashboard that printed the config's model would be right about
        # the file and wrong about the target actually running.
        $model = if ($item.model) { $item.model } else { $Config.model }
        $effort = if ($item.effort) { $item.effort } else { $Config.effort }

        # Only for the row actually being worked on, and only from the tail of its log:
        # this runs on every dashboard refresh, and the answer is in the last few
        # requests. A queued target has no context and a finished one no longer has one.
        $context = 0
        if ($state -in @('running', 'stalled') -and $log -and $log.latestLog) {
            $context = (Get-LogSpend -LogPath $log.latestLog -TailLines 400).last
        }

        $rows += [pscustomobject]@{
            target   = $item.target
            label    = $label
            about    = $about
            model    = $model
            effort   = $effort
            context  = $context
            custom   = [bool] ($item.model -or $item.effort)
            note     = $item.note
            state    = $state
            commits  = $carries
            attempts = $(if ($log) { $log.attempts } else { 0 })
            minutes  = $(if ($log) { $log.minutes } else { $null })
            latest   = $(if ($log) { $log.latest } else { $null })
            first    = $(if ($log) { $log.first } else { $null })
            last     = $(if ($log) { $log.last } else { $null })
        }
    }

    $doneRows = @($rows | Where-Object { $_.state -eq 'done' })
    $remaining = $rows.Count - $doneRows.Count

    # Only logs belonging to THIS sequence set the clock. A log directory outlives the
    # cycle that filled it, and dating the run from a previous cycle's first target would
    # report a pace nobody is working at.
    $starts = @($rows | Where-Object { $null -ne $_.first } | ForEach-Object { $_.first })
    $started = if ($starts.Count -gt 0) { @($starts | Sort-Object)[0] } else { $null }
    $elapsed = if ($started) { ($now - $started).TotalMinutes } else { $null }

    $samples = @($doneRows | Where-Object { $null -ne $_.minutes } | ForEach-Object { [double] $_.minutes })
    $pace = Get-RunPace -TargetMinutes $samples -ElapsedMinutes $elapsed -Finished $doneRows.Count -Remaining $remaining

    # Phases, in the order the sequence first reaches them. The part before the first dot
    # is what `phasekit run <phase>` already treats as a phase, so this grouping is the
    # tool's own and not a second idea of what a target name means.
    $phases = [ordered]@{}
    foreach ($row in $rows) {
        $key = ($row.target -split '\.')[0]
        if (-not $phases.Contains($key)) {
            $title = if ($outline.phases.ContainsKey($key)) { $outline.phases[$key] } else { '' }
            $phases[$key] = [pscustomobject]@{ phase = $key; title = $title; total = 0; done = 0 }
        }
        $phases[$key].total++
        if ($row.state -eq 'done') { $phases[$key].done++ }
    }

    # Whether a runner is actually there. Everything else on the dashboard is inferred
    # from files that outlive the process, so without this a sequence killed an hour ago
    # and one merely between targets draw exactly the same.
    $runner = Get-RunnerState -Config $Config

    $stopFile = Join-Path $Config.logDir 'auto-stopped.txt'
    $doneFile = Join-Path $Config.logDir 'auto-finished.txt'
    $activity = @($rows | Where-Object { $null -ne $_.last } | ForEach-Object { $_.last } | Sort-Object -Descending)

    $stop = $null
    if (Test-Path $stopFile) {
        $marker = Get-Item -LiteralPath $stopFile
        # A stop marker is only cleared when the next sequence starts. Answering a stopped
        # run by hand - a reply, a merge - leaves it behind, and a dashboard that shouted
        # about it would be raising an alarm the owner has already dealt with. Work carried
        # on after it was written is the evidence that they did.
        $stale = ($activity.Count -gt 0 -and $activity[0] -gt $marker.LastWriteTime)
        $stop = [pscustomobject]@{
            when  = $marker.LastWriteTime
            stale = $stale
            text  = @(Get-Content -LiteralPath $stopFile -ErrorAction SilentlyContinue)
        }
    }

    return [pscustomobject]@{
        name      = Split-Path -Leaf $Config.codeDir
        now       = $now
        rows      = $rows
        total     = $rows.Count
        doneCount = $doneRows.Count
        remaining = $remaining
        started   = $started
        elapsed   = $elapsed
        pace      = $pace
        phases    = @($phases.Values)
        stop      = $stop
        runner    = $runner
        outline   = $outline
        model     = $Config.model
        effort    = $Config.effort
        autoCompact = $Config.autoCompact
        logDir    = $Config.logDir
        finished  = (Test-Path $doneFile)
        live      = [bool] @($rows | Where-Object { $_.state -in @('running', 'merging') })
    }
}
