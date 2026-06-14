param(
    [string]$AgentName,
    [string]$CommandId,
    [switch]$UpdateStatus,
    [switch]$Quiet
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$skillRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$safeAgentName = $AgentName -replace "[^a-zA-Z0-9_.-]", "_"
$storeRoot = Join-Path $skillRoot "store\$safeAgentName"
$statusPath = Join-Path $storeRoot "status.json"

# Kill by PID from status.json (precise, no CIM scan)
if (Test-Path $statusPath) {
    try {
        $status = Get-Content $statusPath -Raw | ConvertFrom-Json
        $tuiPid = $status.tui_pid
        if ($tuiPid) {
            try {
                $childProcs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                    Where-Object { $_.ParentProcessId -eq $tuiPid }
                foreach ($c in $childProcs) {
                    Stop-Process -Id $c.ProcessId -Force -ErrorAction SilentlyContinue
                }
            } catch {}
            Stop-Process -Id $tuiPid -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
            # Double-tap if still alive
            if (Get-Process -Id $tuiPid -ErrorAction SilentlyContinue) {
                Stop-Process -Id $tuiPid -Force -ErrorAction SilentlyContinue
            }
            if (-not $Quiet) { Write-Host "Killed PID $tuiPid ($AgentName)" }
        }
    } catch {}
} elseif (-not $Quiet) { Write-Host "No status.json for $AgentName" }

if ($UpdateStatus -and (Test-Path $statusPath)) {
    try {
        $status = Get-Content $statusPath -Raw | ConvertFrom-Json
        function Set-JP { param($O,$N,$V);if($O.PSObject.Properties[$N]){$O.$N=$V}else{$O|Add-Member -N $N -V $V} }
        Set-JP $status "state" "stopped"
        Set-JP $status "tui_pid" $null
        Set-JP $status "updated_at" (Get-Date).ToString("o")
        $status | ConvertTo-Json -Depth 10 | Set-Content $statusPath -Encoding UTF8
    } catch {}
}
if (-not $Quiet) { Write-Host "Cleanup done: $AgentName / $CommandId" }
