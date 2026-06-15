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
$InjectNormal = Get-Arg "-InjectNormal"
if (-not $InjectNormal) { $InjectNormal = "" }

# For remove all -k: collect agent IDs to keep
$KeepIds = @()
if ($Command -eq "remove" -and ($scriptArgs -contains "-k" -or $scriptArgs -contains "-Keep")) {
    $inKeep = $false
    foreach ($a in $scriptArgs) {
        if ($a -eq "-k" -or $a -eq "-Keep") { $inKeep = $true; continue }
        if ($inKeep) {
            if ($a -like "-*") { break }
            $KeepIds += $a
        }
    }
}

$skillRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$agentsPath = Join-Path $skillRoot "manager\agents.json"
$rolesPath = Join-Path $skillRoot "prompt_templates\roles.json"
$roleTemplatesDir = Join-Path $skillRoot "prompt_templates\role"
$sendScript = Join-Path $skillRoot "scripts\Send-ClaudeCommand.ps1"
$stopRuntime = Join-Path $skillRoot "scripts\Stop-ClaudeRuntime.ps1"
$createLockPath = Join-Path $skillRoot "manager\.create-session.lock"

# Resolve default workspace if not explicitly set
if (-not $Workspace) {
    $configPath = Join-Path $skillRoot "manager\config.json"
    if (Test-Path $configPath) {
        try { $cfg = Get-Content $configPath -Raw | ConvertFrom-Json; $Workspace = $cfg.default_workspace } catch {}
    }
    if (-not $Workspace) { $Workspace = $env:CLAUDE_WORKER_DEFAULT_WS }
    if (-not $Workspace) { $Workspace = (Get-Location).Path }
}

# For role register/update: collect -Files and -StateFile values
$RoleFiles = @()
$RoleStateFile = $null
if ($Command -in @("role") -and $scriptArgs.Count -gt 1) {
    for ($i = 2; $i -lt $scriptArgs.Count; $i++) {
        if ($scriptArgs[$i] -eq "-Files" -or $scriptArgs[$i] -eq "-f") {
            for ($j = $i + 1; $j -lt $scriptArgs.Count; $j++) {
                if ($scriptArgs[$j] -like "-*") { break }
                $RoleFiles += $scriptArgs[$j]
            }
            continue
        }
        if ($scriptArgs[$i] -eq "-StateFile" -or $scriptArgs[$i] -eq "-sf") {
            if ($i + 1 -lt $scriptArgs.Count -and $scriptArgs[$i+1] -notlike "-*") {
                $RoleStateFile = $scriptArgs[$i+1]
            }
        }
    }
}

if (-not $Command) {
    Write-Host "ClaudeTui -- Claude Worker Manager"
    Write-Host ""
    Write-Host "Commands: send, agents, agent, wait, result, remove, role"
    Write-Host "  send   <agent_id> -Prompt <p> [-Role <r>] [-Workspace <w>] [-FreshSession] [-TimeoutSeconds <n>] [-Model <name>] [-Mode tui|p] [-InjectNormal <name>]"
    Write-Host "  agents [--all]"
    Write-Host "  agent  <agent_id>"
    Write-Host "  wait   any [<agent_id> ...] | <agent_id> [<agent_id> ...] | all"
    Write-Host "  result <agent_id>"
    Write-Host "  remove <agent_id> | all [-k <id1> [<id2> ...]]"
    Write-Host "  role   register <name> [-Force]"
    Write-Host "  role   update <name> [-Files <path> [<path> ...]] [-StateFile <path>]"
    Write-Host "  role   list | show <name> | unregister <name>"
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
    Ensure-EntryProp $Entry "pending_task_error" $null
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
}

function Capture-FreshSessionUuid {
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
# Role registry helpers
# ====================================================

function Read-Roles {
    $rl = [ordered]@{}
    if (Test-Path -LiteralPath $rolesPath -PathType Leaf) {
        try {
            $raw = Get-Content -LiteralPath $rolesPath -Raw -Encoding UTF8
            if ($raw.Trim()) {
                $parsed = $raw | ConvertFrom-Json
                foreach ($p in $parsed.PSObject.Properties) { $rl[$p.Name] = $p.Value }
            }
        } catch { $rl = [ordered]@{} }
    }
    return $rl
}

function Save-Roles {
    param($Roles)
    $dir = Split-Path -Parent $rolesPath
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $Roles | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $rolesPath -Encoding UTF8
}

# Get role template content (all files concatenated) for prompt injection.
# Returns empty string if role not found or has no templates.
function Get-RoleTemplateContent {
    param([string]$RoleName)
    $roles = Read-Roles
    if (-not $roles.Contains($RoleName)) { return "" }
    $r = $roles[$RoleName]
    if (-not $r.templates -or $r.templates.Count -eq 0) { return "" }
    $dir = Join-Path $roleTemplatesDir $RoleName
    $content = ""
    foreach ($t in $r.templates) {
        $tp = Join-Path $dir $t
        if (Test-Path -LiteralPath $tp -PathType Leaf) {
            $content += "`n$(Get-Content -LiteralPath $tp -Raw -Encoding UTF8)`n"
        }
    }
    return $content
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
            # Timeout-wrapped: zombie PIDs or locked process table can hang Get-Process ~30s
            $procJob = Start-Job -ScriptBlock { param($p) Get-Process -Id $p -ErrorAction SilentlyContinue } -ArgumentList ([int]$pidVal)
            $proc = $null
            if (Wait-Job $procJob -Timeout 3) { $proc = Receive-Job $procJob }
            Remove-Job $procJob -Force -ErrorAction SilentlyContinue
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
        Write-Host "[AUTO-CONTINUE] Queued task for $($as.entry.agent_id) starting now..."
        $pendingInjectNormal = if ($pending.PSObject.Properties["inject_normal"] -and $pending.inject_normal) { $pending.inject_normal } else { "" }
        try {
            Invoke-SendInternal -AgentId $as.entry.agent_id -Prompt $pending.prompt -Role $pending.role -Model $pending.model -InjectNormal $pendingInjectNormal
            # Only after launch success: re-read fresh entry, clear pending_task, save
            Invalidate-Cache; $Agents = Read-Agents
            $foundAfter = Find-ActiveAgent -TargetAgentId $as.entry.agent_id -AgentsDict $Agents
            if ($foundAfter) {
                $foundAfter.entry.pending_task = $null
                $foundAfter.entry.updated_at = (Get-Date).ToString("o")
                Save-Agents -Agents $Agents
            }
        } catch {
            Write-Host "[AUTO-CONTINUE] FAILED: launch/preflight threw; pending_task preserved. Error: $_"
            # Do NOT clear pending_task. Record diagnostic.
            Invalidate-Cache; $Agents = Read-Agents
            $foundAfter = Find-ActiveAgent -TargetAgentId $as.entry.agent_id -AgentsDict $Agents
            if ($foundAfter) {
                if (-not $foundAfter.entry.PSObject.Properties["pending_task_error"]) {
                    $foundAfter.entry | Add-Member -NotePropertyName "pending_task_error" -NotePropertyValue $null
                }
                $foundAfter.entry.pending_task_error = "Auto-continue failed at $(Get-Date -Format 'o'): $_"
                $foundAfter.entry.updated_at = (Get-Date).ToString("o")
                Save-Agents -Agents $Agents
            }
        }
    }
}

function Sync-ReadState {
    param($Agents)
    $changed = $false
    foreach ($key in @($Agents.Keys)) {
        $entry = $Agents[$key]
        if ("deleted" -in $entry.status) { continue }
        if ("running" -notin $entry.status) { continue }
        $task = $entry.current_task
        if (-not $task -or -not $task.command_id) { continue }
        $safe = $entry.agent_id -replace '[^a-zA-Z0-9_.-]', '_'
        $statePath = Join-Path $skillRoot "run\$safe\.$($task.command_id).state"
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { continue }
        try {
            $stateContent = (Get-Content -LiteralPath $statePath -Raw -Encoding UTF8).Trim()
            # v2: JSON format only
            $parsedState = $null
            $isConfirmed = $false
            $stateSummary = $null
            try {
                $stateJson = $stateContent | ConvertFrom-Json
                if ($stateJson.PSObject.Properties["state"]) {
                    $parsedState = [string]$stateJson.state
                }
                if ($stateJson.PSObject.Properties["confirmed"]) {
                    $isConfirmed = [bool]$stateJson.confirmed
                }
                if ($stateJson.PSObject.Properties["summary_message"]) {
                    $stateSummary = [string]$stateJson.summary_message
                }
            } catch {
                # Not valid JSON — skip this state file
                Write-Host ("[STATE] {0}: .state file is not valid JSON, skipping" -f $entry.agent_id)
                continue
            }

            if (-not $parsedState) { continue }

            if (-not $entry.PSObject.Properties["current_state"]) {
                $entry | Add-Member -NotePropertyName "current_state" -NotePropertyValue $null
            }

            if ($entry.current_state -ne $parsedState) {
                $old = $entry.current_state
                $roleName = if ($task.role) { $task.role } else { "explorer" }

                # Validate against legal_state.json (mandatory in v2)
                $roleDir = Join-Path $roleTemplatesDir $roleName
                $legalPath = Join-Path $roleDir "legal_state.json"
                if (-not (Test-Path -LiteralPath $legalPath -PathType Leaf)) {
                    Write-Host ("[STATE] PROTOCOL ERROR: {0} role '{1}' has no legal_state.json" -f $entry.agent_id, $roleName)
                    # Do NOT advance state; skip this agent until role is fixed
                    continue
                }
                try {
                    $legalJson = Get-Content -LiteralPath $legalPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $legalStates = @($legalJson.states | ForEach-Object { [string]$_ })
                    if ($parsedState -notin $legalStates) {
                        Write-Host ("[STATE] HARD ERROR: {0} set illegal state '{1}' (legal: {2}). State NOT applied." -f $entry.agent_id, $parsedState, ($legalStates -join ', '))
                        # Record the error but do NOT update current_state
                        if (-not $entry.PSObject.Properties["state_error"]) {
                            $entry | Add-Member -NotePropertyName "state_error" -NotePropertyValue $null
                        }
                        $entry.state_error = "Illegal state '$parsedState' at $(Get-Date -Format 'o')"
                        $entry.updated_at = (Get-Date).ToString("o")
                        $changed = $true
                        continue
                    }
                } catch {
                    Write-Host ("[STATE] ERROR: Could not parse legal_state.json for role '$roleName'")
                    continue
                }

                $entry.current_state = $parsedState
                $entry.updated_at = (Get-Date).ToString("o")

                Write-Host ("[STATE] {0}: {1} -> {2}" -f $entry.agent_id, $old, $parsedState)
                if ($stateSummary) {
                    Write-Host ("[STATE]   summary: {0}" -f $stateSummary)
                }
                $changed = $true

                # If state=exit and confirmed=true, transition to finishing
                if ($parsedState -eq "exit" -and $isConfirmed) {
                    $entry.status = @("finishing")
                    $entry | Add-Member -NotePropertyName "exit_seen_at" -NotePropertyValue (Get-Date).ToString("o") -Force
                    $entry.updated_at = (Get-Date).ToString("o")
                    Write-Host ("[EXIT] {0}: state=exit confirmed=true, entering finishing" -f $entry.agent_id)
                    $changed = $true
                }
            }
        } catch {}
    }
    if ($changed) { Save-Agents -Agents $Agents }
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

        # v2: No .exit file detection. The ONLY authoritative exit signal is .state JSON
        # (state=exit, confirmed=true), which Sync-ReadState translates to ["finishing"] status.
        # This function handles only the grace period and kill for finishing agents.

        # If already finishing, handle grace period
        if ("finishing" -in $entry.status) {
            $seenAt = try {
                if ($entry.PSObject.Properties["exit_seen_at"]) { [datetime]::Parse($entry.exit_seen_at) }
                else { $null }
            } catch { $null }
            if (-not $seenAt) {
                # No exit_seen_at timestamp, set it now
                $entry | Add-Member -NotePropertyName "exit_seen_at" -NotePropertyValue (Get-Date).ToString("o") -Force
                $entry.updated_at = (Get-Date).ToString("o")
                $changed = $true
                continue
            }
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
            if ($entry.PSObject.Properties["exit_seen_at"]) {
                $entry.PSObject.Properties.Remove("exit_seen_at")
            }
            Write-Host "[EXIT] $($entry.agent_id) cleanup complete"
            $changed = $true
        }
    }
    if ($changed) { Save-Agents -Agents $Agents }
}

function Sync-All {
    param($Agents)
    # 0. Read .state files for progress tracking
    Sync-ReadState -Agents $Agents
    Invalidate-Cache; $Agents = Read-Agents
    # 1. Process agents in finishing status with 5s grace period before kill
    Sync-KillPending -Agents $Agents
    Invalidate-Cache; $Agents = Read-Agents
    # 2. -p mode: runners that wrote done.json and exited cleanly
    Sync-DoneToManager -Agents $Agents
    Invalidate-Cache; $Agents = Read-Agents
    Sync-DeadToFailed -Agents $Agents
    Invalidate-Cache
}

# ====================================================
# Preflight helper — validates role + InjectNormal BEFORE any manager mutation.
# Uses throw (not exit): safe for host-embedded scenarios; top-level dispatch
# will produce non-zero exit via $ErrorActionPreference = "Stop".
# ====================================================

function Assert-SendPreflight {
    param([string]$TargetRole, [string]$TargetInjectNormal)

    $roleDir = Join-Path $roleTemplatesDir $TargetRole
    $legalPath = Join-Path $roleDir "legal_state.json"

    # 1. legal_state.json must exist
    if (-not (Test-Path -LiteralPath $legalPath -PathType Leaf)) {
        throw "Rejected: Role '$TargetRole' has no legal_state.json. Use 'role register $TargetRole' to create a v2 role. Expected at: $legalPath"
    }

    # 2. legal_state.json must be parseable JSON
    try {
        $legalJson = Get-Content -LiteralPath $legalPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Rejected: Role '$TargetRole' legal_state.json is not valid JSON and cannot be parsed."
    }

    # 3. mandatory states: running, exit
    $ls = @($legalJson.states | ForEach-Object { [string]$_ })
    if ("running" -notin $ls) {
        throw "Rejected: Role '$TargetRole' missing mandatory state 'running' in legal_state.json"
    }
    if ("exit" -notin $ls) {
        throw "Rejected: Role '$TargetRole' missing mandatory state 'exit' in legal_state.json"
    }

    # 4. exit_confirmation warning (non-fatal)
    if (-not ($legalJson.PSObject.Properties["exit_confirmation"] -and $legalJson.exit_confirmation)) {
        Write-Host "[MANAGER] WARNING: Role '$TargetRole' legal_state.json has no exit_confirmation."
    }

    # 5. InjectNormal template existence + readability
    if ($TargetInjectNormal) {
        $normalFile = Join-Path $roleDir "normal_prompt\$TargetInjectNormal.md"
        if (-not (Test-Path -LiteralPath $normalFile -PathType Leaf)) {
            throw "Rejected: Normal prompt template '$TargetInjectNormal' not found for role '$TargetRole'. Expected at: $normalFile"
        }
        try {
            $null = Get-Content -LiteralPath $normalFile -Raw -Encoding UTF8 -ErrorAction Stop
        } catch {
            throw "Rejected: Normal prompt template '$TargetInjectNormal' exists but cannot be read: $_"
        }
    }

    Write-Host "[MANAGER] Preflight OK: Role '$TargetRole' legal states: $($ls -join ', ')"
}

# ====================================================
# send
# ====================================================

function Invoke-SendInternal {
    param(
        [string]$AgentId,
        [string]$Prompt,
        [string]$Role = "explorer",
        [string]$Model = "",
        [string]$InjectNormal = ""
    )
    $Agents = Read-Agents
    $found = Find-ActiveAgent -TargetAgentId $AgentId -AgentsDict $Agents
    if (-not $found) {
        $null = Assert-SendPreflight -TargetRole $Role -TargetInjectNormal $InjectNormal
        Write-Host "[MANAGER] Creating new agent: $AgentId"
        $entry = New-AgentEntry -AgentId $AgentId
        $key = $entry.internal_id
        $Agents[$key] = $entry
        _DoLaunch -AgentId $AgentId -Entry $entry -Prompt $Prompt -Role $Role -Model $Model -InjectNormal $InjectNormal
        return
    }
    $entry = $found.entry
    if ("running" -notin $entry.status) {
        $null = Assert-SendPreflight -TargetRole $Role -TargetInjectNormal $InjectNormal
        _DoLaunch -AgentId $AgentId -Entry $entry -Prompt $Prompt -Role $Role -Model $Model -InjectNormal $InjectNormal
        return
    }
    $null = Assert-SendPreflight -TargetRole $Role -TargetInjectNormal $InjectNormal
    Write-Host "[MANAGER] Agent '$AgentId' is busy. Queuing."
    $entry.pending_task = [ordered]@{ prompt = $Prompt; role = $Role; model = $Model; inject_normal = if ($InjectNormal) { $InjectNormal } else { "" } }
    Save-Agents -Agents $Agents
}

function _DoLaunch {
    param($AgentId, $Entry, $Prompt, $Role, $Model, $InjectNormal)

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

    # === Defensive assertion: preflight already passed upstream; refuse if legal_state.json disappeared ===
    $roleDir = Join-Path $roleTemplatesDir $Role
    if (-not (Test-Path -LiteralPath (Join-Path $roleDir "legal_state.json") -PathType Leaf)) {
        throw "INTERNAL ERROR: Role '$Role' legal_state.json lost after preflight. Refusing to launch."
    }

    # Pass -InjectNormal if specified
    if ($InjectNormal) {
        $sendArgs['InjectNormal'] = $InjectNormal
        Write-Host "[MANAGER] Injecting normal_prompt template: $InjectNormal"
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
        if ($LASTEXITCODE -ne 0) { Write-Host $outStr; throw "Send-ClaudeCommand failed with exit code $LASTEXITCODE" }

        try { $launch = $outStr | ConvertFrom-Json }
        catch {
            if ($outStr -match '\{[\s\S]*"command_id"[\s\S]*\}') { $launch = $Matches[0] | ConvertFrom-Json }
            else { Write-Host $outStr; throw "Failed to parse launch JSON from Send-ClaudeCommand output" }
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
            command_id    = $launch.command_id
            prompt        = if ($Prompt.Length -gt 100) { $Prompt.Substring(0,100) + "..." } else { $Prompt }
            role          = $Role
            model         = $Model
            inject_normal = if ($InjectNormal) { $InjectNormal } else { "" }
            launched_at   = $launch.launched_at
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
        $null = Assert-SendPreflight -TargetRole $Role -TargetInjectNormal $InjectNormal
        $entry = New-AgentEntry -AgentId $AgentName
        $key = $entry.internal_id
        $Agents[$key] = $entry
        _DoLaunch -AgentId $AgentName -Entry $entry -Prompt $Prompt -Role $Role -Model $Model -InjectNormal $InjectNormal
        return
    }

    $entry = $found.entry
    if ("running" -notin $entry.status) {
        $null = Assert-SendPreflight -TargetRole $Role -TargetInjectNormal $InjectNormal
        Invalidate-Cache; $Agents = Read-Agents
        $entry = $Agents[$found.key]
        _DoLaunch -AgentId $AgentName -Entry $entry -Prompt $Prompt -Role $Role -Model $Model -InjectNormal $InjectNormal
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
        $null = Assert-SendPreflight -TargetRole $Role -TargetInjectNormal $InjectNormal
        Invalidate-Cache; $Agents = Read-Agents
        $entry = $Agents[$found.key]
        $entry.pending_task = [ordered]@{
            prompt        = $Prompt
            role          = $Role
            model         = $Model
            inject_normal = if ($InjectNormal) { $InjectNormal } else { "" }
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

    Write-Host ("{0,-22} {1,-12} {2,-14} {3,-12} {4,-38}" -f "Agent ID", "Worker State", "State", "Output State", "Session UUID")
    Write-Host ("-" * 88)
    foreach ($e in $filtered) {
        $ws = Get-WorkerState $e
        $os = Get-OutputState $e
        $cs = if ($e.PSObject.Properties["current_state"] -and $e.current_state) { [string]$e.current_state } else { "-" }
        $sid = if ($e.session_uuid) { [string]$e.session_uuid } else { "(none)" }
        Write-Host ("{0,-22} {1,-12} {2,-14} {3,-12} {4,-38}" -f $e.agent_id, $ws, $cs, $os, $sid)
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
    Write-Host "  Current State : $(if ($e.PSObject.Properties["current_state"] -and $e.current_state) { $e.current_state } else { '-' })"
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
        $e.pending_task | ConvertTo-Json -Depth 5 | Write-Host
        Write-Host ""
    }
    if ($e.PSObject.Properties["pending_task_error"] -and $e.pending_task_error) {
        Write-Host "  --- Pending Task Error ---"
        Write-Host "  $($e.pending_task_error)"
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
    $statePath = Join-Path $skillRoot "run\$safe\.$($task.command_id).state"

    # Show state summary first (always available if worker used Update-WorkerState)
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try {
            $stateContent = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8
            try {
                $stateJson = $stateContent | ConvertFrom-Json
                Write-Host "=== State Summary ==="
                Write-Host "Command ID : $($stateJson.command_id)"
                Write-Host "Role       : $($stateJson.role)"
                Write-Host "State      : $($stateJson.state)"
                Write-Host "Confirmed  : $($stateJson.confirmed)"
                Write-Host "Updated    : $($stateJson.updated_at)"
                if ($stateJson.PSObject.Properties["summary_message"] -and $stateJson.summary_message) {
                    Write-Host "Summary    : $($stateJson.summary_message)"
                }
                Write-Host ""
            } catch {
                Write-Host "=== State (text) === "
                Write-Host $stateContent
                Write-Host ""
            }
        } catch {}
    }

    # Show result.md (convenience viewer, not authoritative)
    if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
        Write-Host "=== Result ==="
        Get-Content -LiteralPath $resultPath -Raw
    } else {
        Write-Host "=== Result (no result.md) ==="
        Write-Host "(result.md is optional in v2; use state summary above for task outcome.)"
    }
}

function Invoke-Remove {
    param([string]$Target, [string[]]$Keep = @())

    if (-not $Target) { throw "Usage: ClaudeTui remove <agent_id|all> [-k <id1> ...]" }

    $Agents = Read-Agents

    if ($Target -eq "all") {
        $keepSet = @{}; $Keep | ForEach-Object { $keepSet[$_] = $true }
        $count = 0; $skipped = 0
        foreach ($key in @($Agents.Keys)) {
            $e = $Agents[$key]
            if ("deleted" -in $e.status) { continue }
            if ($keepSet.ContainsKey($e.agent_id)) { $skipped++; continue }
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
        if ($count -eq 0 -and $skipped -eq 0) {
            Write-Host "No removable agents."
        } else {
            Write-Host ("[OK] Soft-deleted {0} agent(s), kept {1}" -f $count, $skipped)
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
# role commands
# ====================================================

function Invoke-RoleRegister {
    param([string]$RoleName, [string[]]$Files, [string]$StateFile, [switch]$Force)

    if (-not $RoleName) { throw "Usage: ClaudeTui role register <name> [-Force]" }
    $safeRole = $RoleName -replace '[^a-zA-Z0-9_.-]', '_'

    $roles = Read-Roles
    if ($roles.Contains($safeRole) -and -not $Force) {
        $existing = $roles[$safeRole]
        Write-Host "[MANAGER] Role '$safeRole' already exists:"
        Write-Host "  Registered by : $($existing.registered_by)"
        Write-Host "  Created       : $($existing.created_at)"
        Write-Host ""
        Write-Host "  Use -Force to overwrite, or choose a different name."
        exit 1
    }

    # Create v2 directory structure with 3 subdirectories + legal_state.json
    $targetDir = Join-Path $roleTemplatesDir $safeRole
    if ($Force) {
        Remove-Item $targetDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $sysDir = Join-Path $targetDir "system_prompt"
    $hdrDir = Join-Path $targetDir "header_prompt"
    $nrmDir = Join-Path $targetDir "normal_prompt"
    New-Item -ItemType Directory -Force -Path $sysDir, $hdrDir, $nrmDir | Out-Null

    # Write default legal_state.json
    $legalPath = Join-Path $targetDir "legal_state.json"
    $defaultLegal = [ordered]@{
        version            = "1"
        states             = @("running", "exit")
        exit_confirmation  = "你确认已经完整执行主控要求的结束流程，并留下主控可验收的结果或证据了吗？"
        description        = "Default legal states for $safeRole"
    }
    $defaultLegal | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $legalPath -Encoding UTF8

    $now = (Get-Date).ToString("o")
    $roles[$safeRole] = [ordered]@{
        role_name      = $safeRole
        registered_by  = if ($env:USERNAME) { $env:USERNAME } else { "unknown" }
        structure      = "v2"
        created_at     = $now
        updated_at     = $now
    }
    Save-Roles $roles
    Write-Host "[MANAGER] Role '$safeRole' registered (v2 structure)"
    Write-Host "  Directories: system_prompt/, header_prompt/, normal_prompt/"
    Write-Host "  legal_state.json: $legalPath"
    Write-Host "  States: running, exit"
    Write-Host ""
    Write-Host "  Next: add .md files to system_prompt/, header_prompt/, normal_prompt/ as needed."
}

function Invoke-RoleUpdate {
    param([string]$RoleName, [string[]]$Files, [string]$StateFile)

    if (-not $RoleName) { throw "Usage: ClaudeTui role update <name>" }
    $safeRole = $RoleName -replace '[^a-zA-Z0-9_.-]', '_'

    $roles = Read-Roles
    if (-not $roles.Contains($safeRole)) { throw "Role '$safeRole' not found. Use 'role register' first." }

    $targetDir = Join-Path $roleTemplatesDir $safeRole
    # Ensure v2 subdirectories exist (create if missing, for upgrade from flat)
    $sysDir = Join-Path $targetDir "system_prompt"
    $hdrDir = Join-Path $targetDir "header_prompt"
    $nrmDir = Join-Path $targetDir "normal_prompt"
    New-Item -ItemType Directory -Force -Path $sysDir, $hdrDir, $nrmDir | Out-Null

    # Ensure legal_state.json exists
    $legalPath = Join-Path $targetDir "legal_state.json"
    if (-not (Test-Path -LiteralPath $legalPath -PathType Leaf)) {
        $defaultLegal = [ordered]@{
            version            = "1"
            states             = @("running", "exit")
            exit_confirmation  = "你确认已经完整执行主控要求的结束流程，并留下主控可验收的结果或证据了吗？"
            description        = "Default legal states for $safeRole"
        }
        $defaultLegal | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $legalPath -Encoding UTF8
        Write-Host "[MANAGER] Created missing legal_state.json for '$safeRole'"
    }

    # If -StateFile provided, update legal_state.json states
    if ($StateFile) {
        if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) { throw "StateFile not found: $StateFile" }
        $st = @(Get-Content -LiteralPath $StateFile | Where-Object { $_.Trim() -ne "" } | ForEach-Object { $_.Trim() })
        if ("exit" -notin $st) { $st += @("exit") }
        if ("running" -notin $st) { $st += @("running") }
        try {
            $ls = Get-Content -LiteralPath $legalPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $ls.states = [array]$st
            $ls | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $legalPath -Encoding UTF8
            Write-Host "[MANAGER] Updated legal_state.json states for '$safeRole': $($st -join ', ')"
        } catch {
            Write-Host "[MANAGER] Failed to update legal_state.json: $_"
        }
    }

    if ($Files -and $Files.Count -gt 0) {
        Write-Host "[MANAGER] ERROR: -Files is not supported in v2."
        Write-Host "  Place .md files directly into:"
        Write-Host "    $sysDir"
        Write-Host "    $hdrDir"
        Write-Host "    $nrmDir"
        exit 1
    }

    $roles[$safeRole].structure = "v2"
    $roles[$safeRole].updated_at = (Get-Date).ToString("o")
    Save-Roles $roles
    Write-Host "[MANAGER] Role '$safeRole' updated."
}

function Invoke-RoleList {
    $roles = Read-Roles
    if ($roles.Count -eq 0) { Write-Host "No roles registered."; return }
    Write-Host ("{0,-26} {1,-16} {2,-10} {3,-20} {4}" -f "Role Name", "Registered By", "Structure", "Updated", "Details")
    Write-Host ("-" * 100)
    foreach ($k in @($roles.Keys)) {
        $r = $roles[$k]
        $struct = if ($r.PSObject.Properties["structure"] -and $r.structure) { $r.structure } else { "flat/v1" }
        $upStr = [string]$r.updated_at; if ($upStr.Length -gt 19) { $upStr = $upStr.Substring(0,19) }
        # Get legal states
        $dir = Join-Path $roleTemplatesDir $k
        $legalPath = Join-Path $dir "legal_state.json"
        $details = ""
        if (Test-Path -LiteralPath $legalPath -PathType Leaf) {
            try {
                $ls = Get-Content -LiteralPath $legalPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $details = "states: $(($ls.states | ForEach-Object { [string]$_ }) -join ',')"
            } catch { $details = "legal_state.json parse error" }
        } elseif ($r.states) {
            $details = "states(v1): $($r.states -join ',')"
        }
        Write-Host ("{0,-26} {1,-16} {2,-10} {3,-20} {4}" -f $r.role_name, $r.registered_by, $struct, $upStr, $details)
    }
    Write-Host ""; Write-Host ("Total: {0} role(s)" -f $roles.Count)
}

function Invoke-RoleShow {
    param([string]$RoleName)
    if (-not $RoleName) { throw "Usage: ClaudeTui role show <name>" }
    $safeRole = $RoleName -replace '[^a-zA-Z0-9_.-]', '_'
    $roles = Read-Roles
    if (-not $roles.Contains($safeRole)) { Write-Host "Role '$safeRole' not found."; exit 1 }
    $r = $roles[$safeRole]
    Write-Host "=========================================="
    Write-Host "  Role: $($r.role_name)"
    Write-Host "=========================================="
    Write-Host "  Registered by : $($r.registered_by)"
    Write-Host "  Structure     : $(if ($r.PSObject.Properties["structure"] -and $r.structure) { $r.structure } else { 'flat (v1)' })"
    Write-Host "  Created       : $($r.created_at)"
    Write-Host "  Updated       : $($r.updated_at)"
    Write-Host ""

    $dir = Join-Path $roleTemplatesDir $safeRole

    # Display legal_state.json
    $legalPath = Join-Path $dir "legal_state.json"
    if (Test-Path -LiteralPath $legalPath -PathType Leaf) {
        Write-Host "  --- legal_state.json ---"
        try {
            $ls = Get-Content -LiteralPath $legalPath -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Host "  States           : $(($ls.states | ForEach-Object { [string]$_ }) -join ', ')"
            if ($ls.PSObject.Properties["exit_confirmation"] -and $ls.exit_confirmation) {
                Write-Host "  Exit Confirmation: $($ls.exit_confirmation)"
            }
            if ($ls.PSObject.Properties["description"] -and $ls.description) {
                Write-Host "  Description      : $($ls.description)"
            }
            if ($ls.PSObject.Properties["version"] -and $ls.version) {
                Write-Host "  Version          : $($ls.version)"
            }
        } catch {
            Write-Host "  (parse error: $_)"
        }
        Write-Host ""
    } else {
        Write-Host "  legal_state.json: NOT FOUND"
        Write-Host ""
    }

    # Display system_prompt files
    $sysDir = Join-Path $dir "system_prompt"
    Write-Host "  --- system_prompt/ ---"
    if (Test-Path -LiteralPath $sysDir -PathType Container) {
        $sysFiles = @(Get-ChildItem -LiteralPath $sysDir -Filter "*.md" -File -ErrorAction SilentlyContinue | Sort-Object Name)
        if ($sysFiles.Count -gt 0) {
            foreach ($sf in $sysFiles) {
                Write-Host "    $($sf.Name) ($($sf.Length) bytes)"
            }
        } else {
            Write-Host "    (empty)"
        }
    } else {
        Write-Host "    (directory not found)"
    }
    Write-Host ""

    # Display header_prompt files
    $hdrDir = Join-Path $dir "header_prompt"
    Write-Host "  --- header_prompt/ ---"
    if (Test-Path -LiteralPath $hdrDir -PathType Container) {
        $hdrFiles = @(Get-ChildItem -LiteralPath $hdrDir -Filter "*.md" -File -ErrorAction SilentlyContinue | Sort-Object Name)
        if ($hdrFiles.Count -gt 0) {
            foreach ($hf in $hdrFiles) {
                Write-Host "    $($hf.Name) ($($hf.Length) bytes)"
            }
        } else {
            Write-Host "    (empty)"
        }
    } else {
        Write-Host "    (directory not found)"
    }
    Write-Host ""

    # Display normal_prompt templates
    $nrmDir = Join-Path $dir "normal_prompt"
    Write-Host "  --- normal_prompt/ (available templates for -InjectNormal) ---"
    if (Test-Path -LiteralPath $nrmDir -PathType Container) {
        $nrmFiles = @(Get-ChildItem -LiteralPath $nrmDir -Filter "*.md" -File -ErrorAction SilentlyContinue | Sort-Object Name)
        if ($nrmFiles.Count -gt 0) {
            foreach ($nf in $nrmFiles) {
                $templateName = $nf.BaseName
                Write-Host "    $templateName ($($nf.Length) bytes)"
                Write-Host "      Usage: send ... -InjectNormal $templateName"
            }
        } else {
            Write-Host "    (no templates available)"
        }
    } else {
        Write-Host "    (directory not found)"
    }
    Write-Host ""

    # Also show any flat files at role root (v1 compat)
    $flatFiles = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike "legal_state.json" })
    if ($flatFiles.Count -gt 0) {
        Write-Host "  --- Root-level files (legacy) ---"
        foreach ($ff in $flatFiles) {
            Write-Host "    $($ff.Name) ($($ff.Length) bytes)"
        }
    }
}

function Invoke-RoleUnregister {
    param([string]$RoleName)
    if (-not $RoleName) { throw "Usage: ClaudeTui role unregister <name>" }
    $safeRole = $RoleName -replace '[^a-zA-Z0-9_.-]', '_'
    $roles = Read-Roles
    if (-not $roles.Contains($safeRole)) { Write-Host "Role '$safeRole' not found."; exit 1 }
    $roles.Remove($safeRole)
    Save-Roles $roles
    Remove-Item (Join-Path $roleTemplatesDir $safeRole) -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "[MANAGER] Role '$safeRole' unregistered."
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
    "remove" { Invoke-Remove -Target $AgentName -Keep $KeepIds }
    "role"   {
        $roleSub = if ($scriptArgs.Count -gt 1) { $scriptArgs[1] } else { "" }
        $roleNameArg = if ($scriptArgs.Count -gt 2 -and $scriptArgs[2] -notlike "-*") { $scriptArgs[2] } else { $null }
        $forceFlag = Has-Flag "-Force"
        switch ($roleSub) {
            "register"    { Invoke-RoleRegister -RoleName $roleNameArg -Files $RoleFiles -StateFile $RoleStateFile -Force:$forceFlag }
            "update"      { Invoke-RoleUpdate -RoleName $roleNameArg -Files $RoleFiles -StateFile $RoleStateFile }
            "list"        { Invoke-RoleList }
            "show"        { Invoke-RoleShow -RoleName $roleNameArg }
            "unregister"  { Invoke-RoleUnregister -RoleName $roleNameArg }
            default       { Write-Host "Usage: ClaudeTui role <register|update|list|show|unregister> [...]"; exit 1 }
        }
    }
    default  {
        if ($Command) {
            Write-Host "Unknown command: $Command"
        }
        Write-Host "Usage: ClaudeTui <send|agents|agent|wait|result|remove> [args...]"
        exit 1
    }
}
