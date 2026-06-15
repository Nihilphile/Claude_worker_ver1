param(
    [Parameter(Mandatory = $true)]
    [string]$AgentName,

    [Parameter(Mandatory = $true)]
    [string]$CommandId,

    [Parameter(Mandatory = $true)]
    [string]$ResultPath,

    [Parameter(Mandatory = $true)]
    [string]$DonePath,

    [string]$ResultText,

    [ValidateSet("completed", "failed", "timeout")]
    [string]$State = "completed",

    [int]$ExitCode = 0,

    [string]$Message = "Claude worker task finished",

    [switch]$NoCleanup
)

<#
.SYNOPSIS
Worker-facing completion: writes done/result files and schedules safe cleanup.
Called by the Claude worker inside the TUI window.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$skillRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$safeAgentName = $AgentName -replace '[^a-zA-Z0-9_.-]', '_'
$storeRoot = Join-Path $skillRoot "store\$safeAgentName"

# Capture runner PID before we overwrite status.json
$statusPath = Join-Path $storeRoot "status.json"
$runnerPid = $null
if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
    try {
        $tmpStatus = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($tmpStatus.PSObject.Properties["tui_pid"]) { $runnerPid = $tmpStatus.tui_pid }
    } catch {}
}

function ConvertTo-SingleQuotedLiteral {
    param([string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

function Assert-PathUnderRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must be under $fullRoot : $fullPath"
    }
}

function Start-SafeTaskCleanup {
    param(
        [Parameter(Mandatory = $true)][string]$AgentName,
        [Parameter(Mandatory = $true)][string]$LiveRoot,
        [Parameter(Mandatory = $true)][string]$CommandId,
        [Parameter(Mandatory = $true)][string]$RuntimeCleanupScript
    )
    $agentNameLiteral = ConvertTo-SingleQuotedLiteral $AgentName
    $commandIdLiteral = ConvertTo-SingleQuotedLiteral $CommandId
    $runtimeCleanupLiteral = ConvertTo-SingleQuotedLiteral $RuntimeCleanupScript
    $cleanupScript = @"
Start-Sleep -Seconds 3
`$agentName = $agentNameLiteral
`$commandId = $commandIdLiteral
`$runtimeCleanup = $runtimeCleanupLiteral
& `$runtimeCleanup -AgentName `$agentName -CommandId `$commandId -UpdateStatus -Quiet
"@
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cleanupScript))
    Start-Process `
        -FilePath "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $encoded) `
        -WindowStyle Hidden | Out-Null
}

Assert-PathUnderRoot -Path $ResultPath -Root $storeRoot -Label "ResultPath"
Assert-PathUnderRoot -Path $DonePath -Root $storeRoot -Label "DonePath"

$resultDir = Split-Path -Parent $ResultPath
$doneDir = Split-Path -Parent $DonePath
New-Item -ItemType Directory -Force -Path $resultDir, $doneDir | Out-Null

if ($PSBoundParameters.ContainsKey("ResultText")) {
    Set-Content -LiteralPath $ResultPath -Value $ResultText -Encoding UTF8
} elseif (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
    "# Task Completed`n`nCommandId: $CommandId`nAgentName: $AgentName" | Set-Content -LiteralPath $ResultPath -Encoding UTF8
} else {
    $existing = (Get-Content -LiteralPath $ResultPath -Raw).Trim()
    if (-not $existing -or $existing -eq "Loading...") {
        "# Task Completed (no structured output)`n`nCommandId: $CommandId`nAgentName: $AgentName`n`nThe worker finished but did not write a detailed result." |
            Set-Content -LiteralPath $ResultPath -Encoding UTF8
    }
}

# Read session UUID (manager captures it from filesystem for TUI mode)
$sid = $null
$sidFile = Join-Path $storeRoot ".claude-sid.txt"
if (Test-Path -LiteralPath $sidFile -PathType Leaf) {
    try { $sid = (Get-Content -LiteralPath $sidFile -Raw).Trim() } catch {}
}
$doneObj = [ordered]@{
    id = $CommandId
    state = $State
    exit_code = $ExitCode
    result = ($ResultPath -replace '\\', '/')
    completed_at = (Get-Date).ToString("o")
    message = $Message
    backend = "claude"
}
if ($sid) { $doneObj['session_id'] = $sid }
$doneObj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $DonePath -Encoding UTF8

# Update manager.json if it exists (for ClaudeTui CLI)
$managerPath = Join-Path $skillRoot "run\manager.json"
if (Test-Path -LiteralPath $managerPath -PathType Leaf) {
    try {
        $mgr = Get-Content -LiteralPath $managerPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $safeName = $safeAgentName
        if ($mgr.PSObject.Properties[$safeName]) {
            $entry = $mgr.$safeName
            if ($entry.PSObject.Properties["state"]) { $entry.state = $State }
            else { $entry | Add-Member -NotePropertyName "state" -NotePropertyValue $State }
            if ($entry.PSObject.Properties["exit_code"]) { $entry.exit_code = $ExitCode }
            else { $entry | Add-Member -NotePropertyName "exit_code" -NotePropertyValue $ExitCode }
            if ($entry.PSObject.Properties["completed_at"]) { $entry.completed_at = (Get-Date).ToString("o") }
            else { $entry | Add-Member -NotePropertyName "completed_at" -NotePropertyValue (Get-Date).ToString("o") }
            if ($entry.PSObject.Properties["tui_pid"]) { $entry.tui_pid = $null }
            else { $entry | Add-Member -NotePropertyName "tui_pid" -NotePropertyValue $null }
            $mgr | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $managerPath -Encoding UTF8
        }
    } catch {}
}

# Update agent status to "stopped" so next Send can proceed
$statusPath = Join-Path $storeRoot "status.json"
if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
    try {
        $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
        if ($status.PSObject.Properties["state"]) { $status.state = "stopped" }
        else { $status | Add-Member -NotePropertyName "state" -NotePropertyValue "stopped" }
        if ($status.PSObject.Properties["tui_pid"]) { $status.tui_pid = $null }
        else { $status | Add-Member -NotePropertyName "tui_pid" -NotePropertyValue $null }
        if ($status.PSObject.Properties["updated_at"]) { $status.updated_at = (Get-Date).ToString("o") }
        else { $status | Add-Member -NotePropertyName "updated_at" -NotePropertyValue (Get-Date).ToString("o") }
        $status | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statusPath -Encoding UTF8
    } catch {}
}

if (-not $NoCleanup) {
    Start-SafeTaskCleanup `
        -AgentName $AgentName `
        -LiveRoot $storeRoot `
        -CommandId $CommandId `
        -RuntimeCleanupScript (Join-Path $skillRoot "scripts\Stop-ClaudeRuntime.ps1")
}

Write-Host "[CLAUDE_WORKER_COMPLETE] $CommandId state=$State exit=$ExitCode"

# DEPRECATED (v2): .exit signal is no longer written by Complete-ClaudeTask.
# In v2, the worker lifecycle is managed via Update-WorkerState --exit --Confirm,
# which writes the .state JSON and .exit signal. The manager reads .state for
# the authoritative exit status. Complete-ClaudeTask is kept as a convenience
# stub for writing result/done files but is no longer required by the worker prompt.
# The manager's Sync-ReadState detects exit from .state JSON, not from .exit here.

exit $ExitCode
