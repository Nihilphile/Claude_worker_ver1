param([string]$AgentName)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$skillRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$registryPath = Join-Path $skillRoot "store\registry.json"
if (-not (Test-Path $registryPath)) { Write-Host "No agents found."; exit 0 }
$reg = Get-Content $registryPath -Raw | ConvertFrom-Json
if ($AgentName) {
    $safe = $AgentName -replace "[^a-zA-Z0-9_.-]", "_"
    if ($reg.PSObject.Properties[$safe]) { $reg.$safe | ConvertTo-Json -Depth 5 }
    else { Write-Host "Agent not found: $AgentName"; exit 1 }
} else {
    Write-Host ("{0,-35} {1,-12} {2,-12} {3}" -f "Agent","State","Role","SessionID")
    Write-Host ("-" * 80)
    foreach ($p in $reg.PSObject.Properties) {
        $a = $p.Value
        Write-Host ("{0,-35} {1,-12} {2,-12} {3}" -f $p.Name, $a.state, $a.role, $a.session_id)
    }
}
