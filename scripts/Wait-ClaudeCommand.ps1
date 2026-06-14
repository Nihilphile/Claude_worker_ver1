param(
    [Parameter(Mandatory = $true)][string]$AgentName,
    [Parameter(Mandatory = $true)][string]$CommandId,
    [int]$TimeoutSeconds = 600,
    [switch]$Quiet
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$skillRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$safeAgentName = $AgentName -replace "[^a-zA-Z0-9_.-]", "_"
$storeRoot = Join-Path $skillRoot "store\$safeAgentName"
$statusPath = Join-Path $storeRoot "status.json"
$registryPath = Join-Path $skillRoot "store\registry.json"
$donePath = Join-Path $storeRoot "results\$CommandId.done.json"
$resultPath = Join-Path $storeRoot "results\$CommandId.result.md"
$stopRuntimePath = Join-Path $skillRoot "scripts\Stop-ClaudeRuntime.ps1"

function Get-JP { param($O,$N); if(-not $O){return $null};$p=$O.PSObject.Properties[$N];if($p){$p.Value}else{$null} }
function Set-JP { param($O,$N,$V);if($O.PSObject.Properties[$N]){$O.$N=$V}else{$O|Add-Member -N $N -V $V} }

function Update-Registry {
    param($Status)
    $reg = [ordered]@{}
    if (Test-Path $registryPath) {
        try { $r=Get-Content $registryPath -Raw|ConvertFrom-Json; foreach($p in $r.PSObject.Properties){$reg[$p.Name]=$p.Value} } catch {}
    }
    $reg[$safeAgentName] = [ordered]@{
        agent_name=Get-JP $Status "agent_name"; safe_agent_name=$safeAgentName
        workspace=Get-JP $Status "workspace"; role=Get-JP $Status "role"
        backend="claude"; session_id=Get-JP $Status "session_id"
        state=Get-JP $Status "state"; last_result=Get-JP $Status "last_result"
        last_done=Get-JP $Status "last_done"; tui_pid=Get-JP $Status "tui_pid"
        updated_at=Get-JP $Status "updated_at"
    }
    $reg|ConvertTo-Json -Depth 10|Set-Content $registryPath -Encoding UTF8
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    if ((Test-Path $donePath) -and (Test-Path $resultPath)) {
        $status = if (Test-Path $statusPath) { Get-Content $statusPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
        Set-JP $status "state" "stopped"
        Set-JP $status "last_result" $resultPath
        Set-JP $status "last_done" $donePath
        Set-JP $status "tui_pid" $null
        Set-JP $status "updated_at" (Get-Date).ToString("o")
        $status|ConvertTo-Json -Depth 10|Set-Content $statusPath -Encoding UTF8
        Update-Registry $status
        if (Test-Path $stopRuntimePath) { & $stopRuntimePath -AgentName $AgentName -CommandId $CommandId -UpdateStatus -Quiet }
        if (-not $Quiet) {
            Write-Host "Done:"; Get-Content $donePath -Raw
            Write-Host "Result:"; Get-Content $resultPath -Raw
        }
        exit 0
    }
    Start-Sleep -Seconds 2
}
Write-Host "Timeout waiting for $CommandId"
exit 124
