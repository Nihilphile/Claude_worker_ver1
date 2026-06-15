<#
.SYNOPSIS
Worker-facing state update (v2). Writes a JSON .state file that the manager polls.
This is the ONLY worker-facing lifecycle/state interface.
--exit requires a confirmation gate: first call prints exit_confirmation,
second call with --Confirm writes the exit state.

USAGE:
  powershell.exe -NoProfile -File Update-WorkerState.ps1 -AgentName <agent> -CommandId <id> -Role <role> --<legal-state> [-Confirm] [-SummaryMessage <text>]

  Examples:
    ... -AgentName my-agent -CommandId 20260615-... -Role coder --running
    ... -AgentName my-agent -CommandId 20260615-... -Role coder --running -SummaryMessage "Implementing phase 2"
    ... -AgentName my-agent -CommandId 20260615-... -Role coder --exit
    ... -AgentName my-agent -CommandId 20260615-... -Role coder --exit -Confirm -SummaryMessage "All done"

  v2 uses --<legal-state> syntax (e.g. --running, --exit). The legacy -State parameter is NOT supported.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# Manual argument parsing (no formal param() block)
# This ensures --<state> switches pass through powershell.exe -File
# ============================================================

$skillRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

$AgentName = $null
$CommandId = $null
$Role = $null
$Confirm = $false
$SummaryMessage = $null
$stateArg = $null
$unknownParams = @()
$i = 0

while ($i -lt $args.Count) {
    $token = $args[$i]
    $next = if ($i + 1 -lt $args.Count) { $args[$i + 1] } else { $null }
    $lc = $token.ToLowerInvariant()

    if ($lc -eq '-agentname') {
        if ($next -eq $null -or $next -like '-*') { Write-Error "-AgentName requires a value"; exit 1 }
        if ($AgentName) { Write-Error "-AgentName specified multiple times"; exit 1 }
        $AgentName = $next; $i += 2; continue
    }
    elseif ($lc -eq '-commandid') {
        if ($next -eq $null -or $next -like '-*') { Write-Error "-CommandId requires a value"; exit 1 }
        if ($CommandId) { Write-Error "-CommandId specified multiple times"; exit 1 }
        $CommandId = $next; $i += 2; continue
    }
    elseif ($lc -eq '-role') {
        if ($next -eq $null -or $next -like '-*') { Write-Error "-Role requires a value"; exit 1 }
        if ($Role) { Write-Error "-Role specified multiple times"; exit 1 }
        $Role = $next; $i += 2; continue
    }
    elseif ($lc -eq '-confirm') {
        $Confirm = $true; $i += 1; continue
    }
    elseif ($lc -eq '-summarymessage') {
        if ($next -eq $null) { Write-Error "-SummaryMessage requires a value"; exit 1 }
        if ($SummaryMessage) { Write-Error "-SummaryMessage specified multiple times"; exit 1 }
        $SummaryMessage = $next; $i += 2; continue
    }
    elseif ($lc -eq '-state') {
        Write-Error "v2 does not use -State. Use --<legal-state> syntax. Examples: --running, --exit, --exit -Confirm"
        Write-Error "Usage: powershell ... -AgentName <agent> -CommandId <id> -Role <role> --<legal-state>"
        exit 1
    }
    elseif ($token -like '--*') {
        if ($stateArg) {
            Write-Error "Multiple state arguments provided. Use exactly one --<legal-state>."
            exit 1
        }
        $stateArg = $token.Substring(2)
        $i += 1; continue
    }
    else {
        $unknownParams += $token
        $i += 1
    }
}

# ============================================================
# Validation
# ============================================================

if ($unknownParams.Count -gt 0) {
    Write-Error "Unknown parameter(s): $($unknownParams -join ', ')"
    Write-Error "Allowed parameters: -AgentName, -CommandId, -Role, -Confirm, -SummaryMessage, --<legal-state>"
    exit 1
}

if (-not $AgentName) {
    Write-Error "Missing required parameter: -AgentName <value>"
    Write-Error "Usage: ... -AgentName <agent> -CommandId <id> -Role <role> --<legal-state>"
    exit 1
}
if (-not $CommandId) {
    Write-Error "Missing required parameter: -CommandId <value>"
    Write-Error "Usage: ... -AgentName <agent> -CommandId <id> -Role <role> --<legal-state>"
    exit 1
}
if (-not $Role) {
    Write-Error "Missing required parameter: -Role <value>"
    Write-Error "Usage: ... -AgentName <agent> -CommandId <id> -Role <role> --<legal-state>"
    exit 1
}
if (-not $stateArg) {
    Write-Error "Missing state argument. Use exactly one --<legal-state>. Examples: --running, --exit"
    Write-Error "Usage: ... -AgentName <agent> -CommandId <id> -Role <role> --<legal-state>"
    exit 1
}

$safeAgentName = $AgentName -replace '[^a-zA-Z0-9_.-]', '_'

# ============================================================
# Role mismatch check
# ============================================================

$statusPath = Join-Path $skillRoot "store\$safeAgentName\status.json"
$agentsPath = Join-Path $skillRoot "manager\agents.json"
$taskRole = $null
if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
    try {
        $status = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $taskRole = $status.role
    } catch {}
}
if (-not $taskRole -and (Test-Path -LiteralPath $agentsPath -PathType Leaf)) {
    try {
        $agents = Get-Content -LiteralPath $agentsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $agents.PSObject.Properties) {
            $entry = $p.Value
            if ($entry.agent_id -eq $AgentName) {
                if ($entry.current_task -and $entry.current_task.role) {
                    $taskRole = [string]$entry.current_task.role
                }
                break
            }
        }
    } catch {}
}
if ($taskRole -and $taskRole -ne $Role) {
    Write-Error "Role mismatch: current task role is '$taskRole', but Update-WorkerState called with Role '$Role'. These must match."
    exit 1
}

# ============================================================
# Load legal_state.json
# ============================================================

$legalStatePath = Join-Path $skillRoot "prompt_templates\role\$Role\legal_state.json"
if (-not (Test-Path -LiteralPath $legalStatePath -PathType Leaf)) {
    Write-Error "Role '$Role' has no legal_state.json at '$legalStatePath'. Ensure the role is registered (v2 format) and the file exists."
    exit 1
}

try {
    $legalState = Get-Content -LiteralPath $legalStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse legal_state.json for role '$Role': $_"
    exit 1
}

$legalStates = @($legalState.states | ForEach-Object { [string]$_ })
if (-not $legalStates -or $legalStates.Count -eq 0) {
    Write-Error "legal_state.json for role '$Role' has no states defined."
    exit 1
}

# ============================================================
# Validate state legality
# ============================================================

if ($stateArg -notin $legalStates) {
    Write-Error "Illegal state '$stateArg'. Legal states for role '$Role': $($legalStates -join ', ')"
    exit 1
}

# ============================================================
# Exit confirmation gate
# ============================================================

if ($stateArg -eq "exit") {
    if (-not $Confirm) {
        $exitMsg = if ($legalState.PSObject.Properties["exit_confirmation"] -and $legalState.exit_confirmation) {
            $legalState.exit_confirmation
        } else {
            "Are you sure you want to set state to exit?"
        }
        Write-Host ""
        Write-Host "================================================"
        Write-Host "  EXIT CONFIRMATION REQUIRED"
        Write-Host "================================================"
        Write-Host "  $exitMsg"
        Write-Host ""
        Write-Host "  To confirm exit and write the exit state, run:"
        Write-Host "    powershell -File Update-WorkerState.ps1 -AgentName $AgentName -CommandId $CommandId -Role $Role --exit -Confirm"
        Write-Host "================================================"
        exit 0
    }
}

# ============================================================
# Write JSON state file
# ============================================================

$runRoot = Join-Path $skillRoot "run\$safeAgentName"
$statePath = Join-Path $runRoot ".$CommandId.state"
$now = (Get-Date).ToString("o")
$stateObj = [ordered]@{
    agent_id        = $AgentName
    command_id      = $CommandId
    role            = $Role
    state           = $stateArg
    confirmed       = ($stateArg -eq "exit" -and $Confirm)
    updated_at      = $now
}
if ($SummaryMessage) {
    $stateObj['summary_message'] = $SummaryMessage
}

$dir = Split-Path -Parent $statePath
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$stateObj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8

Write-Host "[CLAUDE_WORKER_STATE] $CommandId state=$stateArg confirmed=$($stateObj.confirmed)"

# v2: NO .exit signal. Manager lifecycle is driven solely by .state JSON (state=exit, confirmed=true).

exit 0
