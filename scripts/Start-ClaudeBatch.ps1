param([Parameter(Mandatory=$true)][string]$TaskFile)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$skillRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$sendScript = Join-Path $skillRoot "scripts\Send-ClaudeCommand.ps1"
if (-not (Test-Path $TaskFile)) { throw "Task file not found: $TaskFile" }
$tasks = Get-Content $TaskFile -Raw | ConvertFrom-Json
$launched = @()
foreach ($task in $tasks) {
    $p = $task.prompt; $a = $task.agent_name; $w = $task.workspace; $r = $task.role
    $ns = if ($task.fresh_session) { "-FreshSession" } else { "" }
    Write-Host "Launching: $a ($r)"
    $result = & $sendScript -AgentName $a -Workspace $w -Role $r -Prompt $p -NoWait @(if($ns){"-FreshSession"})
    try {
        $info = $result | ConvertFrom-Json
        $launched += [ordered]@{ agent_name=$a; command_id=$info.command_id; pid=$info.tui_pid }
    } catch {
        $launched += [ordered]@{ agent_name=$a; command_id="unknown"; pid="unknown" }
    }
}
Write-Host "Launched $($launched.Count) workers:"
$launched | ConvertTo-Json -Depth 5

# Also save to file for Wait-ClaudeBatch
$batchFile = Join-Path $skillRoot "run\batch-launch-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
New-Item -ItemType Directory -Force -Path (Split-Path $batchFile) | Out-Null
$launched | ConvertTo-Json -Depth 5 | Set-Content $batchFile -Encoding UTF8
Write-Host "Batch record: $batchFile"
