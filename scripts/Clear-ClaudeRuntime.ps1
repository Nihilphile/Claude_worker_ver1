param([switch]$DryRun)
$skillRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$storeDir = Join-Path $skillRoot "store"
if (-not (Test-Path $storeDir)) { Write-Host "No store dir."; exit 0 }
$agents = Get-ChildItem $storeDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "registry.json" }
foreach ($a in $agents) {
    $statusPath = Join-Path $a.FullName "status.json"
    if (Test-Path $statusPath) {
        try {
            $status = Get-Content $statusPath -Raw | ConvertFrom-Json
            $tuiPid = $status.tui_pid
            if ($tuiPid) {
                if ($DryRun) { Write-Host "[DRYRUN] Kill PID $tuiPid ($($a.Name))" }
                else { Stop-Process -Id $tuiPid -Force -ErrorAction SilentlyContinue; Write-Host "Killed PID $tuiPid ($($a.Name))" }
            }
        } catch {}
    }
}
if ($DryRun) { Write-Host "Dry run complete." } else { Write-Host "Cleanup complete." }
