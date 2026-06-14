param(
    [Parameter(Mandatory = $true)][string]$BatchFile,
    [int]$TimeoutSeconds = 600
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$skillRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$waitScript = Join-Path $skillRoot "scripts\Wait-ClaudeCommand.ps1"

if (-not (Test-Path $BatchFile)) { throw "Batch file not found: $BatchFile" }

$entries = Get-Content $BatchFile -Raw | ConvertFrom-Json
if ($entries -isnot [array]) { $entries = @($entries) }

Write-Host "Waiting on $($entries.Count) workers (timeout: ${TimeoutSeconds}s)..."

$results = @()
$total = $entries.Count
$completed = 0
$failed = 0

foreach ($entry in $entries) {
    $agentName = $entry.agent_name
    $commandId = $entry.command_id
    $safeAgentName = $agentName -replace "[^a-zA-Z0-9_.-]", "_"
    $donePath = Join-Path $skillRoot "store\$safeAgentName\results\$commandId.done.json"

    Write-Host "  Waiting: $agentName / $commandId"
    $waitExit = 0
    try {
        & $waitScript -AgentName $agentName -CommandId $commandId -TimeoutSeconds $TimeoutSeconds -Quiet
        $waitExit = $LASTEXITCODE
    } catch {
        $waitExit = 1
    }

    $state = "unknown"
    $exitCode = -1
    $message = ""

    if (Test-Path $donePath) {
        try {
            $done = Get-Content $donePath -Raw | ConvertFrom-Json
            $state = $done.state
            $exitCode = $done.exit_code
            $message = $done.message
        } catch {
            $state = "failed"
            $exitCode = 1
            $message = "Failed to parse done.json"
        }
    } elseif ($waitExit -eq 124) {
        $state = "timeout"
        $exitCode = 124
        $message = "Wait-ClaudeCommand timed out after ${TimeoutSeconds}s"
    } else {
        $state = "failed"
        $exitCode = $waitExit
        $message = "done.json not found; Wait-ClaudeCommand exit code: $waitExit"
    }

    if ($state -eq "completed") { $completed++ } else { $failed++ }

    $results += [ordered]@{
        agent_name = $agentName
        command_id = $commandId
        state = $state
        exit_code = $exitCode
        message = $message
    }
}

$summary = [ordered]@{
    total = $total
    completed = $completed
    failed = $failed
    results = $results
}

Write-Host ""
Write-Host "=== Batch Summary ==="
Write-Host "Total: $total | Completed: $completed | Failed: $failed"
Write-Host "====================="

$summary | ConvertTo-Json -Depth 5
exit $(if ($failed -gt 0) { 1 } else { 0 })
