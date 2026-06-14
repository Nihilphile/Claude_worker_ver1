# === ClaudeTui.ps1 — Manager CLI for Claude Workers ===
# status is an array: @("running") | @("finished","ready") | @("finished","consumed") | @("failed") | @("deleted") | @("finishing")
# Display: Worker State column + Output State column

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$scriptArgs = $args
$Command = if ($scriptArgs.Count -gt 0) { $scriptArgs[0] } else { "" }

function Get-Arg {
    param([string]$Name)
    for ($i = 1; $i -lt $scriptArgs.Count - 1; $i++) {
        if ($scriptArgs[$i] -eq $Name) { return $scriptArgs[$i + 1] }
    }
    return $null
}
function Has-Flag { param([string]$Name); return $Name -in $scriptArgs }

$AgentName = Get-Arg "-AgentName"; if (-not $AgentName) { $AgentName = Get-Arg "-a" }
if (-not $AgentName -and $Command -in @("send","result","remove","wait","agent")) {
    if ($scriptArgs.Count -gt 1 -and $scriptArgs[1] -notlike "-*") { $AgentName = $scriptArgs[1] }
}
# For wait command: collect ALL positional args (support: wait any agent_a, wait agent_a agent_b, etc.)
$AgentNames = @()
if ($Command -eq "wait") {
    for ($i = 1; $i -lt $scriptArgs.Count; $i++) {
        if ($scriptArgs[$i] -notlike "-*") { $AgentNames += $scriptArgs[$i] }
        else { break }
    }
}
$Prompt    = Get-Arg "-Prompt";    if (-not $Prompt)    { $Prompt    = Get-Arg "-p" }
$Workspace = Get-Arg "-Workspace"; if (-not $Workspace) { $Workspace = Get-Arg "-w" }
if (-not $Workspace) { $Workspace = "F:\AI_project\deepseek" }
$Role = Get-Arg "-Role"
if (-not $Role) { $Role = Get-Arg "-r"; if (-not $Role) { $Role = "explorer" } }
$TimeoutVal = Get-Arg "-TimeoutSeconds"
if (-not $TimeoutVal) { $TimeoutVal = Get-Arg "-t" }
if (-not $TimeoutVal) { $TimeoutVal = "600" }
$Model = Get-Arg "-Model"
if (-not $Model) { $Model = Get-Arg "-m" }
$Mode = Get-Arg "-Mode"
if (-not $Mode) { $Mode = Get-Arg "-M" }
$ShowAll = Has-Flag "--all"

$skillRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$agentsPath = Join-Path $skillRoot "manager\agents.json"
$sendScript = Join-Path $skillRoot "scripts\Send-ClaudeCommand.ps1"
$stopRuntime = Join-Path $skillRoot "scripts\Stop-ClaudeRuntime.ps1"
$createLockPath = Join-Path $skillRoot "manager\.create-session.lock"

if (-not $Command) {
    Write-Host "ClaudeTui -- Claude Worker Manager"
    Write-Host ""
    Write-Host "Commands: send, agents, agent, wait, result, remove"
    Write-Host "  send   <agent_id> -Prompt <p> [-Role <r>] [-Workspace <w>] [-FreshSession] [-TimeoutSeconds <n>] [-Model <name>] [-Mode tui|p]"
    Write-Host "  agents [--all]"
    Write-Host "  agent  <agent_id>"
    Write-Host "  wait   any [<agent_id> ...] | <agent_id> [<agent_id> ...] | all"
    Write-Host "  result <agent_id>"
    Write-Host "  remove <agent_id> | all"
    exit 0
}

# ====================================================
# agents.json helpers + status interpreters
# ====================================================

$script:AgentsCache = $null

function Read-Agents {
    if ($script:AgentsCache) { return $script:AgentsCache }
    $ag = [ordered]@{}
    if (Test-Path -LiteralPath $agentsPath -PathType Leaf) {
        try {
            $raw = Get-Content -LiteralPath $agentsPath -Raw -Encoding UTF8
            if ($raw.Trim()) {
                $parsed = $raw | ConvertFrom-Json
                foreach ($p in $parsed.PSObject.Properties) { $ag[$p.Name] = $p.Value }
            }
        } catch { $ag = [ordered]@{} }
    }
    $script:AgentsCache = $ag
    return $ag
}

function Save-Agents {
    param([System.Collections.IDictionary]$Agents)
    $dir = Split-Path -Parent $agentsPath
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $Agents | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $agentsPath -Encoding UTF8
    $script:AgentsCache = $Agents
}

function Invalidate-Cache { $script:AgentsCache = $null }
function New-InternalId { return [guid]::NewGuid().ToString() }

# Parse status array into display columns
function Get-WorkerState {
    param($Entry)
    if ("deleted" -in $Entry.status) { return "deleted" }
    if ("failed" -in $Entry.status)   { return "failed" }
    if ("running" -in $Entry.status)  { return "running" }
    if ("finishing" -in $Entry.status) { return "finishing" }
    if ("finished" -in $Entry.status) { return "finished" }
    return "?"
}

function Get-OutputState {
    param($Entry)
    if ("deleted" -in $Entry.status)   { return "-" }
    if ("ready" -in $Entry.status)     { return "ready" }
    if ("consumed" -in $Entry.status)  { return "consumed" }
    return "none"
}

# Find active agent by agent_id (status does NOT contain "deleted")
function Find-ActiveAgent {
    param(
        [string]$TargetAgentId,
        $AgentsDict
    )
    foreach ($key in @($AgentsDict.Keys)) {
        $entry = $AgentsDict[$key]
        if ($entry.agent_id -eq $TargetAgentId -and "deleted" -notin $entry.status) {
            return @{ key = $key; entry = $entry }
        }
    }
    return $null
}

function New-AgentEntry {
    param([string]$AgentId)
    $now = (Get-Date).ToString("o")
    return [ordered]@{
        internal_id  = (New-InternalId)
        agent_id     = $AgentId
        status       = @("running")
        session_uuid = $null
        default_mode = "p"
        pid          = $null
        current_task = $null
        pending_task = $null
        created_at   = $now
        updated_at   = $now
        deleted_at   = $null
    }
}

function Ensure-EntryProp {
    param($Entry, [string]$Name, $Default)
    if (-not $Entry.PSObject.Properties[$Name]) {
        $Entry | Add-Member -NotePropertyName $Name -NotePropertyValue $Default
    }
}

function Normalize-AgentEntry {
    param($Entry)
    Ensure-EntryProp $Entry "internal_id" (New-InternalId)
    Ensure-EntryProp $Entry "agent_id" "unknown"
    Ensure-EntryProp $Entry "status" @("finished","ready")
    Ensure-EntryProp $Entry "session_uuid" $null
    Ensure-EntryProp $Entry "default_mode" "p"
    Ensure-EntryProp $Entry "pid" $null
    Ensure-EntryProp $Entry "current_task" $null
    Ensure-EntryProp $Entry "pending_task" $null
    Ensure-EntryProp $Entry "created_at" (Get-Date).ToString("o")
    Ensure-EntryProp $Entry "updated_at" (Get-Date).ToString("o")
    Ensure-EntryProp $Entry "deleted_at" $null
}

function Format-Elapsed {
    param([string]$IsoTimestamp)
    if (-not $IsoTimestamp) { return "?" }
    try {
        $ts = [datetime]::Parse($IsoTimestamp)
        $elapsed = [math]::Floor(((Get-Date) - $ts).TotalSeconds)
        if ($elapsed -lt 60) { return "${elapsed}s" }
        if ($elapsed -lt 3600) { return "$([math]::Floor($elapsed/60))m$($elapsed % 60)s" }
        return "$([math]::Floor($elapsed/3600))h$([math]::Floor(($elapsed % 3600)/60))m"
    } catch { return "?" }
}

function Get-ClaudeProjectDir {
    param([string]$WsPath)
    $full = [System.IO.Path]::GetFullPath($WsPath)
    $name = $full -replace '^([A-Z]):\\(.*)$', '$1--$2'
    $name = $name -replace '[\\/_]', '-'
    return Join-Path "$env:USERPROFILE\.claude\projects" $name
}function Capture-FreshSessionUuid {
    param([string]$WorkspacePath, [int]$WaitSeconds = 4)
    Start-Sleep -Seconds $WaitSeconds
    $projDir = Get-ClaudeProjectDir $WorkspacePath
    if (-not (Test-Path $projDir)) { return $null }
    $newest = Get-ChildItem (Join-Path $projDir "*.jsonl") -ErrorAction SilentlyContinue |
        Sort-Object CreationTime -Descending |
        Select-Object -First 1
    if (-not $newest) { return $null }
    return $newest.BaseName
}

# ====================================================
# Sync functions
# ====================================================

function Sync-DeadToFailed {
    param($Agents)
    $changed = $false
    foreach ($key in @($Agents.Keys)) {
        $entry = $Agents[$key]
        if ("deleted" -in $entry.status) { continue }
        if ("running" -notin $entry.status) { continue }
        $pidVal = $entry.pid
        if (-not $pidVal) { continue }
        try {
            $proc = Get-Process -Id ([int]$pidVal) -ErrorAction SilentlyContinue
            if (-not $proc) {
                $entry.status = @("failed"); $entry.pid = $null
                $entry.updated_at = (Get-Date).ToString("o")
                $changed = $true
            }
        } catch {
            $entry.status = @("failed"); $entry.pid = $null
            $entry.updated_at = (Get-Date).ToString("o")
            $changed = $true
        }
    }
    if ($changed) { Save-Agents -Agents $Agents }
}

function Sync-DoneToManager {
    param($Agents)
    $changed = $false
    $autoStarts = @()
    foreach ($key in @($Agents.Keys)) {
        $entry = $Agents[$key]
        if ("deleted" -in $entry.status) { continue }
        if ("running" -notin $entry.status) { continue }
        $task = $entry.current_task
        if (-not $task) { continue }
        if (-not $task.command_id) { continue }
        $safe = $entry.agent_id -replace '[^a-zA-Z0-9_.-]', '_'
        $donePath = Join-Path $skillRoot "store\$safe\results\$($task.command_id).done.json"
        if (-not (Test-Path -LiteralPath $donePath -PathType Leaf)) { continue }
        $exitPath = Join-Path $skillRoot "run\$safe\.$($task.command_id).exit"
        if (Test-Path -LiteralPath $exitPath -PathType Leaf) { continue }
        try {
            $done = Get-Content $donePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $entry.status = @("finished","ready"); $entry.pid = $null
            $entry.updated_at = (Get-Date).ToString("o")
            if ($done.PSObject.Properties["session_id"] -and $done.session_id) {
                $entry.session_uuid = [string]$done.session_id
            }
            $changed = $true
            if ($entry.pending_task) {
                $autoStarts += @{ key = $key; entry = $entry }
            }
        } catch {}
    }
    if ($changed) { Save-Agents -Agents $Agents }
    foreach ($as in $autoStarts) {
        $pending = $as.entry.pending_task
        $as.entry.pending_task = $null
        Save-Agents -Agents $Agents
        Write-Host "[AUTO-CONTINUE] Queued task for $($as.entry.agent_id) starting now..."
        Invoke-SendInternal -AgentId $as.entry.agent_id -Prompt $pending.prompt -Role $pending.role -Model $pending.model
    }
}

function Sync-KillPending {
    param($Agents)
    $changed = $false
    foreach ($key in @($Agents.Keys)) {
        $entry = $Agents[$key]
        if ("deleted" -in $entry.status) { continue }
        if ("running" -notin $entry.status -and "finishing" -notin $entry.status) { continue }
        $task = $entry.current_task
        if (-not $task -or -not $task.command_id) { continue }
        $safe = $entry.agent_id -replace '[^a-zA-Z0-9_.-]', '_'
        $exitPath = Join-Path $skillRoot "run\$safe\.$($task.command_id).exit"
        if (-not (Test-Path -LiteralPath $exitPath -PathType Leaf)) { continue }
        if ("running" -in $entry.status) {
            $entry.status = @("finishing")
            $entry | Add-Member -NotePropertyName "exit_seen_at" -NotePropertyValue (Get-Date).ToString("o") -Force
            $entry.updated_at = (Get-Date).ToString("o")
            Write-Host "[EXIT] $($entry.agent_id) .exit detected, entering 5s grace period"
            $changed = $true
            continue
        }
        $seenAt = try { [datetime]::Parse($entry.exit_seen_at) } catch { $null }
        if (-not $seenAt) { continue }
        $elapsed = ((Get-Date) - $seenAt).TotalSeconds
        if ($elapsed -lt 5) {
            Write-Host "[EXIT] $($entry.agent_id) grace period: $([math]::Floor($elapsed))s / 5s"
            continue
        }
        $killPid = $entry.pid
        if ($killPid) {
            try {
                Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                    Where-Object { $_.ParentProcessId -eq [int]$killPid } |
                    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                Stop-Process -Id ([int]$killPid) -Force -ErrorAction SilentlyContinue
                Write-Host "[EXIT] Killed runner PID $killPid + children for $($entry.agent_id)"
            } catch {
                Write-Host ("[EXIT] Kill attempt for PID $killPid failed: " + $_.Exception.Message)
            }
        }
        $entry.status = @("finished","ready"); $entry.pid = $null
        $entry.updated_at = (Get-Date).ToString("o")
        $entry.PSObject.Properties.Remove("exit_seen_at")
        Remove-Item $exitPath -ErrorAction SilentlyContinue
        Write-Host "[EXIT] $($entry.agent_id) cleanup complete"
        $changed = $true
    }
    if ($changed) { Save-Agents -Agents $Agents }
}

function Sync-All {
    param($Agents)
    Sync-KillPending -Agents $Agents
    Invalidate-Cache; $Agents = Read-Agents
    Sync-DoneToManager -Agents $Agents
    Invalidate-Cache; $Agents = Read-Agents
    Sync-DeadToFailed -Agents $Agents
    Invalidate-Cache
}

# ====================================================
# send
# ====================================================

function Invoke-SendInternal {
    param(
        [string]$AgentId,
        [string]$Prompt,
        [string]$Role = "explorer",
        [string]$Model = ""
    )
    $Agents = Read-Agents
    $found = Find-ActiveAgent -TargetAgentId $AgentId -AgentsDict $Agents
    if (-not $found) {
        Write-Host "[MANAGER] Creating new agent: $AgentId"
        $entry = New-AgentEntry -AgentId $AgentId
        $key = $entry.internal_id
        $Agents[$key] = $entry
        Save-Agents -Agents $Agents
        _DoLaunch -AgentId $AgentId -Entry $entry -Prompt $Prompt -Role $Role -Model $Model
        return
    }
    $entry = $found.entry
    if ("running" -notin $entry.status) {
        _DoLaunch -AgentId $AgentId -Entry $entry -Prompt $Prompt -Role $Role -Model $Model
        return
    }
    Write-Host "[MANAGER] Agent '$AgentId' is busy. Queuing."
    $entry.pending_task = [ordered]@{ prompt = $Prompt; role = $Role; model = $Model }
    Save-Agents -Agents $Agents
}

function _DoLaunch {
    param($AgentId, $Entry, $Prompt, $Role, $Model)

    $fresh = Has-Flag "-FreshSession"
    $isNewSession = (-not $Entry.session_uuid) -or $fresh

    $sendArgs = @{
        Prompt = $Prompt
        AgentName = $AgentId
        Workspace = $Workspace
        Role = $Role
        NoWait = $true
        TimeoutSeconds = [int]$TimeoutVal
    }
    if ($Model) { $sendArgs['Model'] = $Model }
    if ($Mode) { $sendArgs['Mode'] = $Mode }
    if (-not $fresh -and $Entry.session_uuid) {
        $sendArgs['SessionId'] = $Entry.session_uuid
    } elseif (-not $Entry.session_uuid) {
        $sendArgs['FreshSession'] = $true
    }

    $gotLock = $false
    if ($isNewSession) {
        Write-Host "[MANAGER] Acquiring create-session lock..."
        $lockTimeout = 60
        $lockStart = Get-Date
        while (((Get-Date) - $lockStart).TotalSeconds -lt $lockTimeout) {
            try {
                New-Item -Path $createLockPath -ItemType File -ErrorAction Stop | Out-Null
                $gotLock = $true
                Write-Host "[MANAGER] Create-session lock acquired"
                break
            } catch {
                Write-Host "[MANAGER] Waiting for create-session lock..."
                Start-Sleep -Seconds 1
            }
        }
        if (-not $gotLock) { throw "Timed out waiting for create-session lock (${lockTimeout}s)" }
    }

    try {
        Write-Host "[LAUNCH] $AgentId role=$Role session=$($Entry.session_uuid) new=$isNewSession"
        $output = & $sendScript @sendArgs 2>&1
        $outStr = ($output | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { Write-Host $outStr; exit $LASTEXITCODE }

        try { $launch = $outStr | ConvertFrom-Json }
        catch {
            if ($outStr -match '\{[\s\S]*"command_id"[\s\S]*\}') { $launch = $Matches[0] | ConvertFrom-Json }
            else { Write-Host $outStr; exit 1 }
        }

        if ($Entry.PSObject.Properties["exit_seen_at"]) {
            $Entry.PSObject.Properties.Remove("exit_seen_at")
        }

        if ($isNewSession) {
            Write-Host "[MANAGER] Scanning for new session file..."
            $capturedUuid = Capture-FreshSessionUuid -WorkspacePath $Workspace -WaitSeconds 8
            if ($capturedUuid) {
                $Entry.session_uuid = $capturedUuid
                $safe = $AgentId -replace '[^a-zA-Z0-9_.-]', '_'
                $sidFile = Join-Path $skillRoot "store\$safe\.claude-sid.txt"
                Set-Content -LiteralPath $sidFile -Value $capturedUuid -Encoding UTF8
                Write-Host "[MANAGER] Captured session UUID: $capturedUuid"
            } else {
                Write-Host "[MANAGER] WARNING: Could not find new session file. UUID will be captured from done.json later."
            }
        }

        if ($Mode) { $Entry.default_mode = $Mode }
        $Entry.status = @("running")
        $Entry.pid = $launch.tui_pid
        $Entry.current_task = [ordered]@{
            command_id  = $launch.command_id
            prompt      = if ($Prompt.Length -gt 100) { $Prompt.Substring(0,100) + "..." } else { $Prompt }
            role        = $Role
            model       = $Model
            launched_at = $launch.launched_at
        }
        $Entry.updated_at = (Get-Date).ToString("o")
        $Agents = Read-Agents
        $Agents[$Entry.internal_id] = $Entry
        Save-Agents -Agents $Agents
        Write-Host "[OK] $AgentId command_id=$($launch.command_id) pid=$($launch.tui_pid)"
    } finally {
        if ($gotLock) {
            Remove-Item $createLockPath -ErrorAction SilentlyContinue
            Write-Host "[MANAGER] Released create-session lock"
        }
    }
}

function Invoke-Send {
    if (-not $Prompt) { throw "Missing -Prompt" }
    if (-not $AgentName) { throw "Missing -AgentName" }

    $Agents = Read-Agents
    Sync-All -Agents $Agents
    Invalidate-Cache; $Agents = Read-Agents

    $found = Find-ActiveAgent -TargetAgentId $AgentName -AgentsDict $Agents
    if (-not $found) {
        $entry = New-AgentEntry -AgentId $AgentName
        $key = $entry.internal_id
        $Agents[$key] = $entry
        Save-Agents -Agents $Agents
        Invalidate-Cache
        _DoLaunch -AgentId $AgentName -Entry $entry -Prompt $Prompt -Role $Role -Model $Model
        return
    }

    $entry = $found.entry
    if ("running" -notin $entry.status) {
        Invalidate-Cache; $Agents = Read-Agents
        $entry = $Agents[$found.key]
        _DoLaunch -AgentId $AgentName -Entry $entry -Prompt $Prompt -Role $Role -Model $Model
        return
    }

    # BUSY
    $elapsed = Format-Elapsed -IsoTimestamp $entry.current_task.launched_at
    Write-Host ""
    Write-Host "[MANAGER] Agent '$AgentName' is currently BUSY"
    Write-Host "  ====== Status ====================================="
    Write-Host "  Agent ID  : $($entry.agent_id)"
    Write-Host "  Session   : $($entry.session_uuid)"
    Write-Host "  Worker    : running ($elapsed elapsed)"
    Write-Host "  PID       : $($entry.pid)"
    Write-Host "  Task      : $($entry.current_task.prompt)"
    Write-Host "  ====== New Task ==================================="
    Write-Host "  Role      : $Role"
    Write-Host "  Task      : $Prompt"
    Write-Host "  =================================================="
    Write-Host ""
    Write-Host "  [W] Wait   - queue new task, auto-execute after current task finishes"
    Write-Host "  [C] Cancel - abort this send (default)"
    Write-Host ""

    if ([Environment]::UserInteractive) {
        $choice = Read-Host "  Choice [C]"
    } else {
        $choice = "C"
        Write-Host "  (non-interactive, defaulting to Cancel)"
    }

    if ($choice -eq "W" -or $choice -eq "w") {
        Invalidate-Cache; $Agents = Read-Agents
        $entry = $Agents[$found.key]
        $entry.pending_task = [ordered]@{
            prompt = $Prompt
            role   = $Role
            model  = $Model
        }
        $entry.updated_at = (Get-Date).ToString("o")
        Save-Agents -Agents $Agents
        Write-Host "[MANAGER] Task queued for '$AgentName'. Will auto-start on completion."
    } else {
        Write-Host "[MANAGER] Send cancelled."
    }
}

# ====================================================
# agents / agent (display)
# ====================================================

function Invoke-Agents {
    Invalidate-Cache
    $Agents = Read-Agents
    Sync-All -Agents $Agents

    $filtered = @($Agents.Values | Where-Object {
        if (-not $ShowAll -and "deleted" -in $_.status) { return $false }
        return $true
    })

    if ($filtered.Count -eq 0) {
        Write-Host "No agents found."
        if (-not $ShowAll) { Write-Host "Use --all to show deleted agents." }
        return
    }

    Write-Host ("{0,-22} {1,-12} {2,-12} {3,-38}" -f "Agent ID", "Worker State", "Output State", "Session UUID")
    Write-Host ("-" * 88)
    foreach ($e in $filtered) {
        $ws = Get-WorkerState $e
        $os = Get-OutputState $e
        $sid = if ($e.session_uuid) { [string]$e.session_uuid } else { "(none)" }
        Write-Host ("{0,-22} {1,-12} {2,-12} {3,-38}" -f $e.agent_id, $ws, $os, $sid)
        if ($e.current_task -and $e.current_task.prompt) {
            Write-Host ("   Task: {0}" -f $e.current_task.prompt)
        }
    }
    Write-Host ""
    Write-Host ("Total: {0} agents" -f $filtered.Count)
}

function Invoke-AgentDetail {
    param([string]$AgentId)

    if (-not $AgentId) { throw "Usage: ClaudeTui agent <agent_id>" }

    Invalidate-Cache; $Agents = Read-Agents
    Sync-All -Agents $Agents
    Invalidate-Cache; $Agents = Read-Agents

    $found = Find-ActiveAgent -TargetAgentId $AgentId -AgentsDict $Agents
    if (-not $found) { Write-Host "Agent '$AgentId' not found."; exit 1 }

    $e = $found.entry
    Write-Host "=========================================="
    Write-Host "  Agent: $($e.agent_id)"
    Write-Host "=========================================="
    Write-Host "  Internal ID   : $($e.internal_id)"
    Write-Host "  Worker State  : $(Get-WorkerState $e)"
    Write-Host "  Output State  : $(Get-OutputState $e)"
    Write-Host "  Status tags   : $($e.status -join ', ')"
    Write-Host "  Session UUID  : $($e.session_uuid)"
    Write-Host "  Default Mode  : $($e.default_mode)"
    Write-Host "  PID           : $($e.pid)"
    Write-Host "  Created       : $($e.created_at)"
    Write-Host "  Updated       : $($e.updated_at)"
    if ($e.deleted_at) { Write-Host "  Deleted       : $($e.deleted_at)" }
    Write-Host ""

    if ($e.current_task) {
        Write-Host "  --- Current Task ---"
        $e.current_task | ConvertTo-Json -Depth 5 | Write-Host
        Write-Host ""
    }
    if ($e.pending_task) {
        Write-Host "  --- Pending Task ---"
        Write-Host "  Prompt: $($e.pending_task.prompt)"
        Write-Host ""
    }
}

# ====================================================
# wait
# ====================================================

function Invoke-Wait {
    param([string[]]$Targets)

    if (-not $Targets -or $Targets.Count -eq 0) { Write-Host "Usage: ClaudeTui wait <any|all|agent_id [agent_id ...]>"; exit 1 }

    $Agents = Read-Agents

    # ---- wait any <agent_id> [agent_id ...] (subset any) ----
    if ($Targets[0] -eq "any" -and $Targets.Count -ge 2) {
        $subsetTargets = $Targets[1..($Targets.Count-1)]
        Write-Host "[WAIT-ANY] Among: $($subsetTargets -join ', ')"
        while ($true) {
            Sync-All -Agents $Agents
            Invalidate-Cache; $Agents = Read-Agents

            $nextKey = $null
            foreach ($t in $subsetTargets) {
                $found = Find-ActiveAgent -TargetAgentId $t -AgentsDict $Agents
                if (-not $found) { continue }
                $e = $found.entry
                if ("finished" -in $e.status -and "ready" -in $e.status) {
                    $e.status = @("finished","consumed"); $e.updated_at = (Get-Date).ToString("o")
                    Save-Agents -Agents $Agents
                    $nextKey = $found.key; break
                }
            }

            if ($nextKey) {
                $next = $Agents[$nextKey]
                Write-Host "[WAIT-ANY] $($next.agent_id) finished"
                [ordered]@{ agent_id = $next.agent_id; command_id = $next.current_task.command_id } | ConvertTo-Json -Depth 3
                return
            }

            $anyRunning = ($Agents.Values | Where-Object {
                $_.agent_id -in $subsetTargets -and "deleted" -notin $_.status -and ("running" -in $_.status -or "finishing" -in $_.status)
            }).Count -gt 0
            if (-not $anyRunning) { Write-Host "[WAIT-ANY] No running workers in subset."; return }
            Start-Sleep -Seconds 2
        }
    }

    # ---- wait <agent_id> [agent_id ...] (multi-agent all) ----
    if ($Targets[0] -notin @("any","all")) {
        Write-Host "[WAIT] Waiting for: $($Targets -join ', ')"
        $prevDone = -1
        while ($true) {
            Sync-All -Agents $Agents
            Invalidate-Cache; $Agents = Read-Agents

            $done = 0; $total = $Targets.Count
            foreach ($t in $Targets) {
                $found = Find-ActiveAgent -TargetAgentId $t -AgentsDict $Agents
                if (-not $found) { $done++; continue }
                $e = $found.entry
                if ("running" -notin $e.status -and "finishing" -notin $e.status) { $done++ }
            }
            if ($done -eq $total) { break }
            if ($done -ne $prevDone) { Write-Host ("[WAIT] {0}/{1} done" -f $done, $total); $prevDone = $done }
            Start-Sleep -Seconds 2
        }
        if ($total -ge 2) {
            Write-Host "[WAIT] All done."
            foreach ($t in $Targets) {
                $found = Find-ActiveAgent -TargetAgentId $t -AgentsDict $Agents
                if ($found) { Write-Host ("  {0,-22} {1}" -f $t, (Get-WorkerState $found.entry)) }
                else { Write-Host ("  {0,-22} (removed)" -f $t) }
            }
        } else {
            $found = Find-ActiveAgent -TargetAgentId $Targets[0] -AgentsDict $Agents
            if ($found) { Write-Host "[WAIT] $($Targets[0]) done (Worker: $(Get-WorkerState $found.entry))" }
        }
        return
    }

    $Target = $Targets[0]

    if ($Target -eq "any") {
        while ($true) {
            Sync-All -Agents $Agents
            Invalidate-Cache; $Agents = Read-Agents

            $nextKey = $null
            foreach ($key in @($Agents.Keys)) {
                $e = $Agents[$key]
                if ("deleted" -in $e.status) { continue }
                if ("finished" -in $e.status -and "ready" -in $e.status) {
                    $e.status = @("finished","consumed")
                    $e.updated_at = (Get-Date).ToString("o")
                    Save-Agents -Agents $Agents
                    $nextKey = $key
                    break
                }
            }

            if ($nextKey) {
                $next = $Agents[$nextKey]
                Write-Host "[WAIT-ANY] $($next.agent_id) finished"
                [ordered]@{ agent_id = $next.agent_id; command_id = $next.current_task.command_id } | ConvertTo-Json -Depth 3
                return
            }

            $anyRunning = ($Agents.Values | Where-Object {
                "deleted" -notin $_.status -and ("running" -in $_.status -or "finishing" -in $_.status)
            }).Count -gt 0

            if (-not $anyRunning) { Write-Host "[WAIT-ANY] No running workers."; return }
            Start-Sleep -Seconds 2
        }
    }

    if ($Target -eq "all") {
        while ($true) {
            Sync-All -Agents $Agents
            Invalidate-Cache; $Agents = Read-Agents
            $running = @($Agents.Values | Where-Object {
                "deleted" -notin $_.status -and ("running" -in $_.status -or "finishing" -in $_.status)
            })
            if ($running.Count -eq 0) { break }
            Write-Host ("[WAIT-ALL] {0} workers still running..." -f $running.Count)
            Start-Sleep -Seconds 2
        }
        Write-Host "[WAIT-ALL] All workers finished."
        Invoke-Agents
        return
    }

    $found = Find-ActiveAgent -TargetAgentId $Target -AgentsDict $Agents
    if (-not $found) { Write-Host "[WAIT] '$Target' not found."; exit 1 }

    while ($true) {
        Sync-All -Agents $Agents
        Invalidate-Cache; $Agents = Read-Agents
        $found = Find-ActiveAgent -TargetAgentId $Target -AgentsDict $Agents
        if (-not $found) { Write-Host "[WAIT] '$Target' removed."; return }
        if ("running" -notin $found.entry.status -and "finishing" -notin $found.entry.status) {
            Write-Host "[WAIT] $Target done (Worker: $(Get-WorkerState $found.entry))"
            $found.entry | ConvertTo-Json -Depth 5
            return
        }
        Start-Sleep -Seconds 2
    }
}

# ====================================================
# result / remove
# ====================================================

function Invoke-Result {
    param([string]$AgentId)

    if (-not $AgentId) { throw "Usage: ClaudeTui result <agent_id>" }

    $Agents = Read-Agents
    $found = Find-ActiveAgent -TargetAgentId $AgentId -AgentsDict $Agents
    if (-not $found) { Write-Host "Agent '$AgentId' not found."; exit 1 }

    $task = $found.entry.current_task
    if (-not $task -or -not $task.command_id) {
        Write-Host "No task record for '$AgentId'."
        return
    }

    $safe = $AgentId -replace '[^a-zA-Z0-9_.-]', '_'
    $resultPath = Join-Path $skillRoot "store\$safe\results\$($task.command_id).result.md"
    if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
        Get-Content -LiteralPath $resultPath -Raw
    } else {
        Write-Host "(result.md not found at $resultPath)"
    }
}

function Invoke-Remove {
    param([string]$Target)

    if (-not $Target) { throw "Usage: ClaudeTui remove <agent_id|all>" }

    $Agents = Read-Agents

    if ($Target -eq "all") {
        $count = 0
        foreach ($key in @($Agents.Keys)) {
            $e = $Agents[$key]
            if ("deleted" -in $e.status) { continue }
            if ("running" -in $e.status -or "finishing" -in $e.status) {
                Write-Host "[SKIP] $($e.agent_id) is running, cannot remove"
                continue
            }
            $e.status = @("deleted")
            $e.deleted_at = (Get-Date).ToString("o")
            $e.updated_at = (Get-Date).ToString("o")
            $count++
        }
        Save-Agents -Agents $Agents
        if ($count -eq 0) {
            Write-Host "No removable agents."
        } else {
            Write-Host "[OK] Soft-deleted $count agent(s)."
        }
        return
    }

    $found = Find-ActiveAgent -TargetAgentId $Target -AgentsDict $Agents
    if (-not $found) { Write-Host "'$Target' not found."; exit 1 }
    if ("running" -in $found.entry.status -or "finishing" -in $found.entry.status) {
        Write-Host "'$Target' is running. Cannot remove a running agent."
        exit 1
    }
    $found.entry.status = @("deleted")
    $found.entry.deleted_at = (Get-Date).ToString("o")
    $found.entry.updated_at = (Get-Date).ToString("o")
    Save-Agents -Agents $Agents
    Write-Host "[OK] Soft-deleted '$Target' (agent_id is now free to reuse)."
    Write-Host "    Internal ID: $($found.key) — use this to restore later."
}

# ====================================================
# dispatch
# ====================================================

switch ($Command) {
    "send"   { Invoke-Send }
    "agents" { Invoke-Agents }
    "agent"  { Invoke-AgentDetail -AgentId $AgentName }
    "wait"   { Invoke-Wait -Targets $AgentNames }
    "result" { Invoke-Result -AgentId $AgentName }
    "remove" { Invoke-Remove -Target $AgentName }
    default  {
        if ($Command) {
            Write-Host "Unknown command: $Command"
        }
        Write-Host "Usage: ClaudeTui <send|agents|agent|wait|result|remove> [args...]"
        exit 1
    }
}
