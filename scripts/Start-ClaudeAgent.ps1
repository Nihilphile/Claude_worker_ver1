param(
    [string]$AgentName = "claude-worker",
    [string]$Workspace = ""
    [string]$Role = "explorer"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$skillRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$safeAgentName = $AgentName -replace "[^a-zA-Z0-9_.-]", "_"
$storeRoot = Join-Path $skillRoot "store\$safeAgentName"
$runRoot = Join-Path $skillRoot "run\$safeAgentName"
$registryPath = Join-Path $skillRoot "store\registry.json"
$statusPath = Join-Path $storeRoot "status.json"
$resultsDir = Join-Path $storeRoot "results"
$logsDir = Join-Path $runRoot "logs"
New-Item -ItemType Directory -Force -Path $storeRoot, $runRoot, $resultsDir, $logsDir | Out-Null
$sessionId = if (Test-Path $statusPath) { try { (Get-Content $statusPath -Raw | ConvertFrom-Json).session_id } catch { $null } } else { $null }
if (-not $sessionId) { $sessionId = [guid]::NewGuid().ToString() }
$status = [ordered]@{
    agent_name = $AgentName; state = "ready"; workspace = $Workspace; role = $Role
    backend = "claude"; model = "claude"; model_provider = "deepseek-anthropic"
    session_id = $sessionId; thread_id = $sessionId; live_root = $storeRoot
    last_result = $null; last_done = $null; last_done_state = $null
    tui_pid = $null; updated_at = (Get-Date).ToString("o"); message = "Agent initialized"
}
$status | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statusPath -Encoding UTF8
$regDir = Split-Path -Parent $registryPath
New-Item -ItemType Directory -Force -Path $regDir | Out-Null
$reg = [ordered]@{}
if (Test-Path $registryPath) { try { $r = Get-Content $registryPath -Raw | ConvertFrom-Json; foreach ($p in $r.PSObject.Properties) { $reg[$p.Name] = $p.Value } } catch {} }
$reg[$safeAgentName] = $status
$reg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $registryPath -Encoding UTF8
Write-Host "Agent ready: $AgentName SessionId=$sessionId"
