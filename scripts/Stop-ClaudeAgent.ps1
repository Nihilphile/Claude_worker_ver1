param([Parameter(Mandatory=$true)][string]$AgentName)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"
$skillRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
& (Join-Path $skillRoot "scripts\Stop-ClaudeRuntime.ps1") -AgentName $AgentName -UpdateStatus
Write-Host "Agent stopped: $AgentName"
