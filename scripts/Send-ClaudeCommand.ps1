param(
    [Parameter(Mandatory = $true)]
    [string]$Prompt,
    [string]$AgentName = "claude-worker",
    [string]$Workspace = "",
    [string]$Role = "explorer",
    [switch]$NoStartIfMissing,
    [switch]$FreshSession,
    [switch]$NoWait,
    [int]$TimeoutSeconds = 600,
    [string]$Model = "",
    [string]$SessionId = "",
    [ValidateSet("p", "tui")]
    [string]$Mode = "p",
    [string]$InjectNormal = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$skillRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$safeAgentName = $AgentName -replace '[^a-zA-Z0-9_.-]', '_'
$storeRoot = Join-Path $skillRoot "store\$safeAgentName"
$runRoot = Join-Path $skillRoot "run\$safeAgentName"
$registryPath = Join-Path $skillRoot "store\registry.json"
$statusPath = Join-Path $storeRoot "status.json"
$threadPath = Join-Path $storeRoot "thread.json"
$resultsDir = Join-Path $storeRoot "results"
$logsDir = Join-Path $runRoot "logs"
$completeScriptPath = Join-Path $skillRoot "scripts\Complete-ClaudeTask.ps1"
$stopRuntimePath = Join-Path $skillRoot "scripts\Stop-ClaudeRuntime.ps1"
$claudeJsonPath = Join-Path $env:USERPROFILE ".claude.json"

Write-Host "Send-ClaudeCommand loading..."
Write-Host "AgentName=$AgentName Role=$Role Workspace=$Workspace"

# ---- helpers ----

function Get-JsonProp { param($Obj, [string]$N); if (-not $Obj) { return $null }; $p = $Obj.PSObject.Properties[$N]; if ($p) { return $p.Value }; return $null }
function First-Val { foreach ($v in $args) { if ($null -ne $v -and "$v" -ne "") { return $v } }; return $null }
function Set-JsonProp { param($Obj, [string]$N, $V); if ($Obj.PSObject.Properties[$N]) { $Obj.$N = $V } else { $Obj | Add-Member -NotePropertyName $N -NotePropertyValue $V } }
function ConvertTo-PSLiteral { param($V); if ($null -eq $V -or "$V" -eq "") { return "`$null" }; return "'" + ([string]$V -replace "'", "''") + "'" }

# ---- workspace trust ----

function Ensure-ClaudeWorkspaceTrust {
    param([string]$WsPath)
    if (-not (Test-Path -LiteralPath $claudeJsonPath -PathType Leaf)) {
        Write-Host "[TRUST] .claude.json not found, skipping"
        return
    }
    $normalized = ([System.IO.Path]::GetFullPath($WsPath)).Replace("\", "/").TrimEnd("/")
    try {
        $claudeCfg = Get-Content -LiteralPath $claudeJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Host "[TRUST] Failed to parse .claude.json"
        return
    }
    if (-not $claudeCfg.PSObject.Properties["projects"]) {
        $claudeCfg | Add-Member -NotePropertyName "projects" -NotePropertyValue ([ordered]@{})
    }
    if (-not $claudeCfg.projects.PSObject.Properties[$normalized]) {
        $claudeCfg.projects | Add-Member -NotePropertyName $normalized -NotePropertyValue ([ordered]@{})
    }
    $proj = $claudeCfg.projects.$normalized
    $trust = Get-JsonProp -Obj $proj -N "hasTrustDialogAccepted"
    if ($trust -ne $true) {
        Set-JsonProp -Obj $proj -N "hasTrustDialogAccepted" -V $true
        $claudeCfg | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $claudeJsonPath -Encoding UTF8
        Write-Host "[TRUST] Granted: $normalized"
    } else {
        Write-Host "[TRUST] Already trusted: $normalized"
    }
}

# ---- registry ----

function Update-AgentRegistry {
    param($Status)
    $regDir = Split-Path -Parent $registryPath
    New-Item -ItemType Directory -Force -Path $regDir | Out-Null
    $reg = [ordered]@{}
    if (Test-Path -LiteralPath $registryPath -PathType Leaf) {
        try {
            $raw = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
            foreach ($p in $raw.PSObject.Properties) { $reg[$p.Name] = $p.Value }
        } catch { $reg = [ordered]@{} }
    }
    $existing = if ($reg.Contains($safeAgentName)) { $reg[$safeAgentName] } else { $null }
    $reg[$safeAgentName] = [ordered]@{
        agent_name      = First-Val (Get-JsonProp -Obj $Status -N "agent_name") (Get-JsonProp -Obj $existing -N "agent_name")
        safe_agent_name = $safeAgentName
        workspace       = First-Val (Get-JsonProp -Obj $Status -N "workspace") (Get-JsonProp -Obj $existing -N "workspace")
        role            = First-Val (Get-JsonProp -Obj $Status -N "role") (Get-JsonProp -Obj $existing -N "role")
        backend         = "claude"
        live_root       = First-Val (Get-JsonProp -Obj $Status -N "live_root") (Get-JsonProp -Obj $existing -N "live_root")
        thread_id       = First-Val (Get-JsonProp -Obj $Status -N "thread_id") (Get-JsonProp -Obj $existing -N "thread_id")
        session_id      = First-Val (Get-JsonProp -Obj $Status -N "session_id") (Get-JsonProp -Obj $existing -N "session_id")
        state           = Get-JsonProp -Obj $Status -N "state"
        last_result     = Get-JsonProp -Obj $Status -N "last_result"
        last_done       = Get-JsonProp -Obj $Status -N "last_done"
        tui_pid         = Get-JsonProp -Obj $Status -N "tui_pid"
        updated_at      = Get-JsonProp -Obj $Status -N "updated_at"
        model           = "claude"
        model_provider  = "deepseek-anthropic"
    }
    $reg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $registryPath -Encoding UTF8
}

# ---- status / session ----

function New-AgentStatus {
    param([string]$Sid, [string]$StateVal)
    return [pscustomobject][ordered]@{
        agent_name      = $AgentName
        state           = $StateVal
        workspace       = $Workspace
        role            = $Role
        backend         = "claude"
        model           = "claude"
        model_provider  = "deepseek-anthropic"
        session_id      = $Sid
        thread_id       = $Sid
        live_root       = $storeRoot
        last_result     = $null
        last_done       = $null
        last_done_state = $null
        tui_pid         = $null
        updated_at      = (Get-Date).ToString("o")
        message         = $null
    }
}

function Get-AgentSessionId {
    param($Status)
    $sid = Get-JsonProp -Obj $Status -N "session_id"
    if ($sid) { return [string]$sid }
    if (Test-Path -LiteralPath $threadPath -PathType Leaf) {
        try {
            $ti = Get-Content -LiteralPath $threadPath -Raw | ConvertFrom-Json
            $sid = Get-JsonProp -Obj $ti -N "session_id"
            if ($sid) { return [string]$sid }
        } catch {}
    }
    return $null
}

# ---- done file reader ----

function Read-DoneFile {
    param([string]$Path)
    # Retry up to 3 times in case file is being written (TOCTOU protection)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
            return ($raw | ConvertFrom-Json)
        } catch {
            if ($attempt -lt 3) { Start-Sleep -Milliseconds 500 } else { throw }
        }
    }
}

# ---- completion handler ----

function Complete-AgentCommand {
    param($Status, $Done, [string]$Msg)
    # Re-read status from disk in case runner updated session_id (real Claude UUID)
    if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
        try {
            $diskStatus = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $diskSid = Get-JsonProp -Obj $diskStatus -N "session_id"
            Write-Host "[DBG-CAC] disk status sid=$diskSid, prev in-memory sid=$(Get-JsonProp -Obj $Status -N 'session_id')"
            if ($diskSid) { Set-JsonProp -Obj $Status -N "session_id" -V $diskSid }
        } catch {}
    }
    $doneState = [string]$Done.state
    if (-not $doneState) { $doneState = "failed" }
    Set-JsonProp -Obj $Status -N "state" -V "stopped"
    Set-JsonProp -Obj $Status -N "message" -V $Msg
    Set-JsonProp -Obj $Status -N "last_result" -V $resultPath
    Set-JsonProp -Obj $Status -N "last_done" -V $donePath
    Set-JsonProp -Obj $Status -N "last_done_state" -V $doneState
    Set-JsonProp -Obj $Status -N "tui_pid" -V $null
    Set-JsonProp -Obj $Status -N "updated_at" -V (Get-Date).ToString("o")
    $Status | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statusPath -Encoding UTF8
    Update-AgentRegistry -Status $Status
}

function Invoke-RuntimeCleanup {
    param([string]$Cid)
    if (Test-Path -LiteralPath $stopRuntimePath -PathType Leaf) {
        & $stopRuntimePath -AgentName $AgentName -CommandId $Cid -UpdateStatus -Quiet
    }
}

# ---- precise process cleanup ----

function Stop-TaskProcess {
    param([int]$Pid)
    try {
        $proc = Get-Process -Id $Pid -ErrorAction SilentlyContinue
        if ($proc) {
            # Kill child processes first, then parent
            $children = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                Where-Object { $_.ParentProcessId -eq $Pid } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Stop-Process -Id $Pid -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
            # Verify: if still alive, force-kill tree
            if (Get-Process -Id $Pid -ErrorAction SilentlyContinue) {
                Stop-Process -Id $Pid -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {}
}

# ---- prompt builder ----

# ---- prompt templates (from disk, editable) ----
$templatesDir = Join-Path $skillRoot "prompt_templates\default"

function Build-SystemPrompt {
    $sysPath = Join-Path $templatesDir "system.md"
    if (Test-Path -LiteralPath $sysPath -PathType Leaf) {
        return (Get-Content -LiteralPath $sysPath -Raw -Encoding UTF8).Trim()
    }
    return ""
}

function Build-WorkerPrompt {
    param([string]$UserPrompt)
    # Read header template, replace role placeholder
    $headerPath = Join-Path $templatesDir "header.md"
    $header = "[worker]`nYou are a $Role agent. Execute the task, then complete."
    if (Test-Path -LiteralPath $headerPath -PathType Leaf) {
        $header = (Get-Content -LiteralPath $headerPath -Raw -Encoding UTF8).Trim()
        $header = $header -replace '~~ROLE~~', $Role
    }

    # --- InjectNormal: load and prepend normal_prompt template ---
    $injectBlock = ""
    if ($InjectNormal) {
        $normalFile = Join-Path $skillRoot "prompt_templates\role\$Role\normal_prompt\$InjectNormal.md"
        Write-Host "[INJECT-NORMAL] Loading: $normalFile"
        if (-not (Test-Path -LiteralPath $normalFile -PathType Leaf)) {
            throw "InjectNormal error: Normal prompt template '$InjectNormal' not found for role '$Role'. Expected at: $normalFile"
        }
        try {
            $normalContent = (Get-Content -LiteralPath $normalFile -Raw -Encoding UTF8).Trim()
        } catch {
            throw "InjectNormal error: Normal prompt template '$InjectNormal' exists but cannot be read: $_"
        }
        $injectBlock = @"


INJECTED NORMAL PROMPT: $InjectNormal (role: $Role)
$normalContent
"@
    }

    return @"
$header
Automated pipeline. No confirmation needed. No exploring beyond the task.

MANDATORY COMPLETION — after the task, do these steps:
1. Write a summary of what you did to: $resultPath
2. Call: powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$completeScriptPath" -AgentName "$AgentName" -CommandId "$commandId" -ResultPath "$resultPath" -DonePath "$donePath"
If task failed: add -State failed -ExitCode 1. Step 2 is non-negotiable.
$injectBlock
TASK:
$UserPrompt
"@
}
function Write-LaunchSummary {
    param([string]$Cid, [string]$DPath, [string]$RPath, [string]$RunPath, [string]$PPath, [int]$TPid, [string]$Sid)
    [ordered]@{
        agent_name        = $AgentName
        safe_agent_name   = $safeAgentName
        command_id        = $Cid
        done_path         = $DPath
        result_path       = $RPath
        status_path       = $statusPath
        runner_path       = $RunPath
        prompt_path       = $PPath
        tui_pid           = $TPid
        session_id        = $Sid
        backend           = "claude"
        launched_at       = (Get-Date).ToString("o")
    } | ConvertTo-Json -Depth 8
}

# ====================================================
# MAIN
# ====================================================

# 1. Ensure workspace trust
Ensure-ClaudeWorkspaceTrust -WsPath $Workspace

# 2. Auto-initialize agent if missing
if ((-not $NoStartIfMissing) -and -not (Test-Path -LiteralPath $statusPath -PathType Leaf)) {
    $startScript = Join-Path $skillRoot "scripts\Start-ClaudeAgent.ps1"
    if (Test-Path -LiteralPath $startScript -PathType Leaf) {
        & $startScript -AgentName $AgentName -Workspace $Workspace -Role $Role
    }
}
if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) {
    throw "Agent status not found and -NoStartIfMissing supplied: $statusPath"
}

# 3. Create directories
New-Item -ItemType Directory -Force -Path $storeRoot, $runRoot, $resultsDir, $logsDir | Out-Null

# 3b. Check if agent is already running — heal stale state if process is dead
if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
    try {
        $prevStatus = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($prevStatus.state -eq "running") {
            $prevPid = if ($prevStatus.PSObject.Properties["tui_pid"]) { $prevStatus.tui_pid } else { $null }
            $processAlive = $false
            if ($prevPid) {
                try { $processAlive = [bool](Get-Process -Id ([int]$prevPid) -ErrorAction SilentlyContinue) } catch {}
            }
            if (-not $processAlive) {
                Write-Host "[HEAL] Agent '$AgentName' marked running but PID $prevPid is dead. Auto-cleaning."
                $prevStatus.state = "stopped"
                if ($prevStatus.PSObject.Properties["tui_pid"]) { $prevStatus.tui_pid = $null }
                else { $prevStatus | Add-Member -NotePropertyName "tui_pid" -NotePropertyValue $null }
                $prevStatus.updated_at = (Get-Date).ToString("o")
                $prevStatus | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statusPath -Encoding UTF8
            } else {
                throw "Agent '$AgentName' is currently running (PID $prevPid). Wait or use a different name."
            }
        }
    } catch {
        if ($_.Exception.Message -match "currently running") { throw }
    }
}

# 3c. Acquire per-agent lock
$lockPath = Join-Path $runRoot ".send.lock"
$lockHeld = $false
try {
    New-Item -Path $lockPath -ItemType File -ErrorAction Stop | Out-Null
    $lockHeld = $true
} catch {
    throw "Agent '$AgentName' is busy (another Send-ClaudeCommand is in progress for this agent)."
}

try {
    # 4. Load status + resolve session
    $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
# FreshSession overrides everything — runner must create a new Claude session
if ($FreshSession) {
    $curSessionId = ""
    Write-Host "[SESSION] Fresh session requested (will capture real UUID from Claude)"
} elseif ($SessionId) {
    $curSessionId = $SessionId
    Write-Host "[SESSION] Using orchestrator-provided UUID: $curSessionId"
} else {
    $curSessionId = Get-AgentSessionId -Status $status
    Write-Host "[DBG] FreshSession=$FreshSession, status.sid=$($status.session_id), resolved=$curSessionId"
    if (-not $curSessionId) {
        $curSessionId = ""
        Write-Host "[SESSION] No prior session, starting fresh"
    } else {
        Write-Host "[SESSION] Resume session: $curSessionId"
    }
}

# 5. Generate command ID + paths
$commandId = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$donePath = Join-Path $resultsDir "$commandId.done.json"
$resultPath = Join-Path $resultsDir "$commandId.result.md"
$runnerPath = Join-Path $runRoot "run-command-$commandId.ps1"
$promptPath = Join-Path $runRoot "run-command-$commandId.prompt.txt"
$transcriptPath = Join-Path $logsDir "$commandId.transcript.log"
$windowTitle = "Claude Worker - $safeAgentName - $commandId"
$launchedAt = Get-Date

Write-Host "CommandId=$commandId"
Write-Host "StoreRoot=$storeRoot RunRoot=$runRoot"

# 5b. Ensure worker permissions file exists
$permsFile = Join-Path $skillRoot ".claude\worker-permissions.json"
if (-not (Test-Path $permsFile)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $permsFile) | Out-Null
    @'
{
  "permissions": {
    "allow": [
      "Bash(*)",
      "Edit(*)",
      "Read(*)",
      "Write(*)",
      "WebFetch(*)",
      "WebSearch(*)"
    ]
  }
}
'@ | Set-Content -LiteralPath $permsFile -Encoding UTF8
    Write-Host "[PERMS] Created worker permissions file"
}

# 6. Build full prompt + system prompt + write to file
$fullPrompt = Build-WorkerPrompt -UserPrompt $Prompt
Set-Content -LiteralPath $promptPath -Value $fullPrompt -Encoding UTF8
Write-Host "Prompt written: $promptPath ($($fullPrompt.Length) chars)"

# Build system prompt (runtime contract, injected via --append-system-prompt) and write to file
$systemPrompt = Build-SystemPrompt
$systemPromptPath = Join-Path $runRoot "run-command-$commandId.system.txt"
if ($systemPrompt) {
    Set-Content -LiteralPath $systemPromptPath -Value $systemPrompt -Encoding UTF8
    Write-Host "System prompt written: $systemPromptPath ($($systemPrompt.Length) chars)"
} else {
    $systemPromptPath = ""
}

# 7. Update status
$status = New-AgentStatus -Sid $curSessionId -StateVal "running"
$status | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statusPath -Encoding UTF8
Update-AgentRegistry -Status $status

# 8. Write thread info
[ordered]@{
    thread_id       = $curSessionId
    session_id      = $curSessionId
    workspace       = $Workspace
    role            = $Role
    backend         = "claude"
    model           = "claude"
    model_provider  = "deepseek-anthropic"
    last_command_id = $commandId
    updated_at      = (Get-Date).ToString("o")
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $threadPath -Encoding UTF8

# 9. Generate runner script
if ("$Mode" -eq "tui") {
    # ---- TUI mode ----
    $tuiTemplate = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = "Continue"
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new(`$false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(`$false)
`$OutputEncoding = [System.Text.UTF8Encoding]::new(`$false)
chcp 65001 | Out-Null
`$host.UI.RawUI.WindowTitle = "$windowTitle [TUI]"

`$env:NO_COLOR = "1"
`$env:CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS = "1"
`$env:CLAUDE_WORKER_AGENT = "$AgentName"
`$env:CLAUDE_WORKER_COMMAND_ID = "$commandId"
`$env:CLAUDE_WORKER_LIVE_ROOT = "$storeRoot"

Write-Host "========================================"
Write-Host "  Claude Worker [TUI MODE]"
Write-Host "  Agent : $AgentName"
Write-Host "  Cmd   : $commandId"
Write-Host "  Role  : $Role"
Write-Host "  Session: $curSessionId"
Write-Host "  Time  : `$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")"
Write-Host "========================================"
Write-Host ""

Set-Location -LiteralPath "$Workspace"

`$settingsJson = "$permsFile"
`$modelArg = if ("$Model" -ne "") { @("--model","$Model") } else { @() }
`$baseArgs = @("--dangerously-skip-permissions","--permission-mode","bypassPermissions","--add-dir","$Workspace","--settings",`$settingsJson) + `$modelArg

# Resume decision uses orchestrator-passed UUID, NOT .claude-sid.txt.
# .claude-sid.txt is written by manager for SUBSEQUENT launches.
# The current launch either has a known UUID (--resume) or starts fresh.
if ("$curSessionId" -ne "") {
    `$fullArgs = `$baseArgs + @("--resume", "$curSessionId")
    Write-Host "[RUNNER] Resuming session: $curSessionId"
} else {
    `$fullArgs = `$baseArgs
    Write-Host "[RUNNER] Starting fresh session (manager will capture UUID from filesystem)"
}
# Pass prompt as variable — avoids double-quote issues from prompt content
`$promptContent = Get-Content -LiteralPath "$promptPath" -Raw -Encoding UTF8
if (`$promptContent) { `$fullArgs += ,`$promptContent }

# Append system prompt (runtime contract, compression-resistant)
if ("$systemPromptPath" -ne "") { `$fullArgs += @("--system-prompt-file", "$systemPromptPath") }
Write-Host "[RUNNER] Launching Claude..."
& claude @fullArgs
`$exit = `$LASTEXITCODE

# After Claude exits: ensure done.json exists with session_id
if (-not (Test-Path "$donePath")) {
    `$sid = if (Test-Path `$sidFile) { (Get-Content `$sidFile -Raw).Trim() } else { "" }
    @{id="$commandId";state="completed";exit_code=`$exit;result="$resultPath";completed_at=(Get-Date).ToString("o");message="Claude exited without Complete-ClaudeTask";backend="claude";session_id=`$sid} | ConvertTo-Json | Set-Content "$donePath" -Encoding UTF8
}

Write-Output "exit=`$exit" | Out-File -LiteralPath "$transcriptPath" -Encoding UTF8
"@
    Set-Content -LiteralPath $runnerPath -Value $tuiTemplate -Encoding UTF8
} else {
    # ---- -p mode (default) ----
    $pTemplate = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = "Continue"
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new(`$false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(`$false)
`$OutputEncoding = [System.Text.UTF8Encoding]::new(`$false)
chcp 65001 | Out-Null
`$host.UI.RawUI.WindowTitle = "$windowTitle"

`$env:NO_COLOR = "1"
`$env:CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS = "1"
`$env:CLAUDE_WORKER_AGENT = "$AgentName"
`$env:CLAUDE_WORKER_COMMAND_ID = "$commandId"
`$env:CLAUDE_WORKER_LIVE_ROOT = "$storeRoot"

Write-Host "========================================"
Write-Host "  Claude Worker"
Write-Host "  Agent : $AgentName"
Write-Host "  Cmd   : $commandId"
Write-Host "  Role  : $Role"
Write-Host "  Session: $curSessionId"
Write-Host "  Time  : `$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")"
Write-Host "========================================"
Write-Host ""

Set-Location -LiteralPath "$Workspace"

`$workerPrompt = Get-Content -LiteralPath "$promptPath" -Raw -Encoding UTF8
`$settingsJson = "$permsFile"

`$modelArg = if ("$Model" -ne "") { @("--model","$Model") } else { @() }
`$baseArgs = @("--dangerously-skip-permissions","--permission-mode","bypassPermissions","--add-dir","$Workspace","--settings",`$settingsJson) + `$modelArg

`$sysPromptArgs = if ("$systemPromptPath" -ne "") { @("--system-prompt-file","$systemPromptPath") } else { @() }

# -p mode. If session UUID provided, resume it; otherwise start fresh.
if ("$curSessionId" -ne "") {
    `$jsonOut = & claude @baseArgs --resume "$curSessionId" -p --output-format json `$workerPrompt `$sysPromptArgs
} else {
    `$jsonOut = & claude @baseArgs -p --output-format json `$workerPrompt `$sysPromptArgs
}
`$exit = `$LASTEXITCODE

if (`$exit -eq 0 -and `$jsonOut) {
    try {
        `$j = `$jsonOut | ConvertFrom-Json
        Set-Content "$resultPath" `$j.result -Encoding UTF8
        `$sid = if (`$j.session_id) { `$j.session_id } else { "$curSessionId" }
        # Store real Claude UUID for manager to pick up
        `$sidFile = Join-Path "$storeRoot" ".claude-sid.txt"
        Set-Content `$sidFile `$sid -Encoding UTF8
        # done.json with session_id — manager Sync-DoneToManager reads this
        @{id="$commandId";state="completed";exit_code=0;result="$resultPath";completed_at=(Get-Date).ToString("o");message="ok";backend="claude";session_id=`$sid} | ConvertTo-Json | Set-Content "$donePath" -Encoding UTF8
    } catch { Write-Host "[PARSE]" }
}

Write-Output "exit=`$exit" | Out-File -LiteralPath "$transcriptPath" -Encoding UTF8
"@
    Set-Content -LiteralPath $runnerPath -Value $pTemplate -Encoding UTF8
}

Write-Host "Runner written: $runnerPath"
# 10. Launch visible window
$proc = Start-Process `
    -FilePath "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $runnerPath) `
    -WorkingDirectory $Workspace `
    -WindowStyle Normal `
    -PassThru

Set-JsonProp -Obj $status -N "tui_pid" -V $proc.Id
Set-JsonProp -Obj $status -N "updated_at" -V (Get-Date).ToString("o")
$status | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statusPath -Encoding UTF8
Update-AgentRegistry -Status $status

Write-Host "Launched Claude Worker"
Write-Host "AgentName=$AgentName"
Write-Host "CommandId=$commandId"
Write-Host "PID=$($proc.Id)"

# Release lock — runner is launched, tui_pid written, critical section done
if ($lockHeld) {
    Remove-Item $lockPath -ErrorAction SilentlyContinue
    $lockHeld = $false
}
} finally {
    # Safety net: release lock on exception inside critical section
    if ($lockHeld) { Remove-Item $lockPath -ErrorAction SilentlyContinue }
}

# 11. -NoWait: return immediately
if ($NoWait) {
    Write-LaunchSummary `
        -Cid $commandId -DPath $donePath -RPath $resultPath `
        -RunPath $runnerPath -PPath $promptPath `
        -TPid $proc.Id -Sid $curSessionId
    exit 0
}

# 12. Blocking wait loop
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    if ((Test-Path -LiteralPath $donePath -PathType Leaf) -and (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
        $done = Read-DoneFile -Path $donePath
        Complete-AgentCommand -Status $status -Done $done -Msg "Claude worker task finished"
        Invoke-RuntimeCleanup -Cid $commandId

        Write-Host ""
        Write-Host "=== Task Complete ==="
        Write-Host "State: $($done.state)"
        Write-Host "ExitCode: $($done.exit_code)"
        Write-Host "Result: $resultPath"
        exit ([int]$done.exit_code)
    }

    $proc.Refresh()
    if ($proc.HasExited) {
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            "" | Set-Content -LiteralPath $resultPath -Encoding UTF8
        }
        $pe = 1
        if ($null -ne $proc.ExitCode -and [int]$proc.ExitCode -ne 0) {
            $pe = [int]$proc.ExitCode
        }
        if (-not (Test-Path -LiteralPath $donePath -PathType Leaf)) {
            [ordered]@{
                id           = $commandId
                state        = "failed"
                exit_code    = $pe
                result       = $resultPath
                completed_at = (Get-Date).ToString("o")
                message      = "Claude worker process exited before writing done/result files"
            } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $donePath -Encoding UTF8
        }

        $failedDone = Read-DoneFile -Path $donePath
        Complete-AgentCommand -Status $status -Done $failedDone -Msg "Worker process exited before completion"
        Invoke-RuntimeCleanup -Cid $commandId

        Write-Host ""
        Write-Host "=== Worker Exited Early ==="
        Get-Content -LiteralPath $donePath -Raw
        exit $pe
    }

    Start-Sleep -Seconds 2
}

# 13. Timeout
"" | Set-Content -LiteralPath $resultPath -Encoding UTF8
[ordered]@{
    id           = $commandId
    state        = "timeout"
    exit_code    = 124
    result       = $resultPath
    completed_at = (Get-Date).ToString("o")
    message      = "Timed out waiting for Claude worker completion after ${TimeoutSeconds}s"
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $donePath -Encoding UTF8

$timeoutDone = Read-DoneFile -Path $donePath
Complete-AgentCommand -Status $status -Done $timeoutDone -Msg "Timed out waiting for completion"
Invoke-RuntimeCleanup -Cid $commandId

Write-Host ""
Write-Host "=== Timeout ==="
Get-Content -LiteralPath $donePath -Raw
exit 124

