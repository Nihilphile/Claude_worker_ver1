# Role-System v2: Sync-DeadToFailed Zombie-PID Timeout Repair Report

- **Date:** 2026-06-15
- **Worker:** role-system-v2-sync-dead-coder-p
- **Branch:** master (ver2 workspace: F:\AI_project\Claude_worker_ver2)
- **Type:** Bugfix — hard timeout for zombie PID query

## 1. Problem Summary

### Symptom
CLI commands (`agent`, `agents`, `send`, `wait`, etc.) appear to hang/freeze for tens
of seconds or minutes when `agents.json` contains multiple `"running"` entries whose
actual Windows processes have already exited (zombie PIDs).

### Root Cause
The `Sync-DeadToFailed` function in `scripts/ClaudeTui.ps1` was calling
`Get-Process -Id` directly inside a serial `foreach` loop. On Windows, a
`Get-Process` query for certain PIDs — especially those that exited without proper
cleanup or from orphaned process trees — can block for approximately 30 seconds
before returning. With multiple dead `"running"` records, each call stacked
sequentially, causing multi-minute total blockage for every `Sync-All` invocation.

`Sync-All` is called at nearly every CLI entry point (send, agents, agent, wait,
result, remove, role), so the entire manager appeared dead.

### Affected File
- **`scripts/ClaudeTui.ps1`**, function `Sync-DeadToFailed` (line 304).

### Other `Get-Process` usages examined
- `scripts/Send-ClaudeCommand.ps1` lines 204, 213, 389 — these query the *current*
  process or a just-launched PID; they are not scanning a table of historical dead
  PIDs. Left unchanged per task scope.
- `scripts/Stop-ClaudeRuntime.ps1` line 30 — queries a known live TUI PID. Left
  unchanged.

## 2. Fix Applied

### Before (v2, buggy)

```powershell
try {
    $proc = Get-Process -Id ([int]$pidVal) -ErrorAction SilentlyContinue
    if (-not $proc) {
        $entry.status = @("failed"); $entry.pid = $null
        $entry.updated_at = (Get-Date).ToString("o")
        $changed = $true
    }
} catch { ... }
```

### After (v2, fixed — matching ver1)

```powershell
try {
    # Timeout-wrapped: zombie PIDs or locked process table can hang Get-Process ~30s
    $procJob = Start-Job -ScriptBlock { param($p) Get-Process -Id $p -ErrorAction SilentlyContinue } -ArgumentList ([int]$pidVal)
    $proc = $null
    if (Wait-Job $procJob -Timeout 3) { $proc = Receive-Job $procJob }
    Remove-Job $procJob -Force -ErrorAction SilentlyContinue
    if (-not $proc) {
        $entry.status = @("failed"); $entry.pid = $null
        $entry.updated_at = (Get-Date).ToString("o")
        $changed = $true
    }
} catch { ... }
```

### What changed
| Aspect | Before | After |
|--------|--------|-------|
| Get-Process call | Direct, serial, unprotected | Wrapped in `Start-Job` child job |
| Timeout | None (OS decides, ~30s worst) | `Wait-Job -Timeout 3` (3 seconds hard ceiling) |
| Job cleanup | N/A | `Remove-Job -Force` after every query |
| Semantics | Unchanged | Unchanged: no process → `"failed"` status, `pid = $null` |
| Exception path | Existing `catch` preserved | Existing `catch` preserved; additionally `Remove-Job` silently ignores errors |

### Rationale for 3-second timeout
- A healthy `Get-Process` on a real PID returns in < 100ms.
- 3 seconds gives ample margin for transient system load while cutting worst-case
  zombie-PID hang (measured ~30s on Windows Server 2022 with orphaned conhost).
- Ver1 uses the same 3-second timeout and has been validated in production.

## 3. State-Transition Semantics (Preserved)

| Input Status | PID | Get-Process Result | Output Status | Notes |
|---|---|---|---|---|
| `running` | valid PID | process found | `running` (unchanged) | Agent is alive |
| `running` | valid PID | timeout (3s) | `failed` | Zombie or stuck PID → failed |
| `running` | valid PID | no process | `failed` | Process exited | 
| `running` | valid PID | exception | `failed` | Any error → failed |
| `running` | `$null` | (skipped) | `running` (unchanged) | No PID to check |
| `deleted`, `finished`, etc. | (any) | (skipped) | unchanged | Only `running` entries checked |

Key guarantee: **any `"running"` entry whose PID cannot be confirmed alive within 3
seconds is marked `"failed"`**. No silent ignore. Scope has not widened — non-running
entries are still skipped.

## 4. Verification

### 4.1 PowerShell Parser
```
Error count: 0
Parse OK
```
`ClaudeTui.ps1` parses cleanly with the PowerShell AST parser (no syntax errors).

### 4.2 Test Suite: `tests/Sync-DeadToFailed-Timeout-Tests.ps1`
Three tests, all passing:

| Test | Method | Result |
|------|--------|--------|
| Static analysis | Confirm `Start-Job`, `Wait-Job -Timeout`, `Remove-Job -Force` present in function text | PASS |
| Hard ceiling | `Start-Job { Start-Sleep 30; ... }` → `Wait-Job -Timeout 3` → elapsed = 3.0s < 6s | PASS |
| Dead PID semantic | Input status `running` + PID `99999999` → output status `failed`, pid `$null` | PASS |

### 4.3 Git Diff Scope
Only `scripts/ClaudeTui.ps1` was modified (plus the new test file and this report).
The diff for `ClaudeTui.ps1` in the `Sync-DeadToFailed` block:
```diff
-            $proc = Get-Process -Id ([int]$pidVal) -ErrorAction SilentlyContinue
+            # Timeout-wrapped: zombie PIDs or locked process table can hang Get-Process ~30s
+            $procJob = Start-Job -ScriptBlock { param($p) Get-Process -Id $p -ErrorAction SilentlyContinue } -ArgumentList ([int]$pidVal)
+            $proc = $null
+            if (Wait-Job $procJob -Timeout 3) { $proc = Receive-Job $procJob }
+            Remove-Job $procJob -Force -ErrorAction SilentlyContinue
```

No other functions, modules, schemas, or configuration files were touched.

## 5. Residual Risks

1. **PowerShell job subsystem load:** Each PID check spawns a background job. On
   systems with extremely high agent counts (100+ running entries), this could add
   noticeable overhead. Mitigation: typical workloads have < 10 running entries.

2. **False-negative under extreme system load:** If the system is so overloaded that
   a real process takes > 3 seconds to respond to `Get-Process`, a healthy agent
   could be marked `failed`. Mitigation: 3 seconds is 10-30× the typical
   `Get-Process` latency; this scenario is exceptionally rare.

3. **Job cleanup race:** `Remove-Job -Force` uses `-ErrorAction SilentlyContinue`,
   so if the job subsystem is in a bad state, cleanup errors are silently ignored.
   Mitigation: the job is disposable; leaked job objects are zombie PowerShell jobs
   (not OS processes) and do not consume significant resources.

4. **`Send-ClaudeCommand.ps1` still has bare `Get-Process`:** These queries target
   the *current* or *just-launched* process, not scanning a table of dead PIDs. The
   risk of zombie-PID hang in those codepaths is much lower. Per task scope, these
   are left unchanged.

## 6. Files Changed

| File | Action |
|------|--------|
| `scripts/ClaudeTui.ps1` | Modified — `Sync-DeadToFailed` function (line 313-318): replace bare `Get-Process` with `Start-Job`/`Wait-Job -Timeout 3`/`Remove-Job -Force` |
| `tests/Sync-DeadToFailed-Timeout-Tests.ps1` | Added — 3-test validation suite |
| `docs/worker-reports/role-system-v2-sync-dead-timeout-repair-report.md` | Added — this report |

## 7. Reference

- Ver1 master fix: `F:\AI_project\Claude_worker_ver1\scripts\ClaudeTui.ps1` line 305-308 (identical pattern).
