# Role System v2 — InjectNormal Boundary Repair Review Report

> **Author**: role-system-v2-injectnormal-reviewer-p
> **Date**: 2026-06-15 22:25 UTC+8
> **Verdict**: **PASS** — Both repairs are correctly implemented. No regressions, no security issues.

---

## 1. Scope & Method

Independent review of the boundary repair (reported in `role-system-v2-injectnormal-boundary-repair-report.md`) that addressed two findings from the queue transaction final review:

- **Issue 1 (Medium)**: InjectNormal silently lost at Send-ClaudeCommand.ps1 boundary
- **Issue 2 (Low)**: `pending_task_error` not displayed in `agent detail`

The review is **strictly read-only**: no file mutations, no git commits, no real Claude launched. Only lightweight PowerShell validation was executed.

### Reviewed Sources

| Source | Role |
|--------|------|
| `docs/worker-reports/role-system-v2-queue-final-review-report.md` | Original findings (Findings 1 & 2) |
| `docs/worker-reports/role-system-v2-injectnormal-boundary-repair-report.md` | Repair claims |
| `scripts/Send-ClaudeCommand.ps1` (673 lines) | Injection logic, Build-WorkerPrompt |
| `scripts/ClaudeTui.ps1` (1455 lines) | Manager: _DoLaunch, Invoke-AgentDetail, Normalize-AgentEntry |
| `tests/Mock-SendFixture.ps1` (234 lines) | 19 source-invariant verification tests |
| `prompt_templates/role/*/normal_prompt/` | Live template directories (explorer: 3, test: 3) |

---

## 2. Verification Results

### 2.1 PowerShell AST Parsing — CLEAN

| File | AST Errors |
|------|-----------|
| `scripts/ClaudeTui.ps1` | 0 |
| `scripts/Send-ClaudeCommand.ps1` | 0 |

### 2.2 Mock-SendFixture (19 tests) — ALL PASS

```
Test  1: Invoke-Send new-agent path - no Save-Agents before _DoLaunch ........ PASS
Test  2: Invoke-SendInternal new-agent path - no Save-Agents before _DoLaunch  PASS
Test  3: _DoLaunch uses throw (not exit) for launch failures ................ PASS
Test  4: _DoLaunch - single atomic Save-Agents ............................. PASS
Test  5: pending_task includes inject_normal ............................... PASS
Test  6: Sync-DoneToManager reads and passes inject_normal ................. PASS
Test  7: Auto-continue defers pending_task clear until after launch ........ PASS
Test  8: Auto-continue failure preserves pending_task (catch block) ....... PASS
Test  9: Invoke-AgentDetail displays pending_task via ConvertTo-Json ....... PASS
Test 10: tests/ directory - no unused mock files .......................... PASS
Test 11: No }function missing-newline formatting issue .................... PASS
Test 12: _DoLaunch + Invoke-SendInternal have explicit InjectNormal params . PASS
Test 13: current_task records inject_normal ............................... PASS
Test 14: agents-json-schema.md synchronized ............................... PASS
Test 15: Send-ClaudeCommand.ps1 declares InjectNormal parameter ............. PASS
Test 16: Build-WorkerPrompt injects normal_prompt .......................... PASS
Test 17: Build-WorkerPrompt gates behind if ($InjectNormal) ................ PASS
Test 18: Invoke-AgentDetail displays pending_task_error .................... PASS
Test 19: Normalize-AgentEntry normalizes pending_task_error ................ PASS
```

### 2.3 _DoLaunch Call Site Verification

All 4 `_DoLaunch` call sites pass `-InjectNormal` explicitly:

| # | Location | Passes -InjectNormal |
|---|----------|---------------------|
| 1 | Invoke-SendInternal new-agent (line 634) | Yes |
| 2 | Invoke-SendInternal idle-agent (line 640) | Yes |
| 3 | Invoke-Send new-agent (line 770) | Yes |
| 4 | Invoke-Send idle-agent (line 779) | Yes |

---

## 3. Review Findings — Per Criterion

### 3.1 Send-ClaudeCommand declares InjectNormal; manager params not lost — PASS

**Repair applied**: `[string]$InjectNormal = ""` added to top-level `param()` block in `Send-ClaudeCommand.ps1` (line 15).

**Parameter flow verified end-to-end**:

```
CLI (-InjectNormal <name>)
  -> ClaudeTui.ps1 $InjectNormal (line 47)
    -> _DoLaunch $InjectNormal param (line 649)
      -> $sendArgs['InjectNormal'] = $InjectNormal (line 679)
        -> & $sendScript @sendArgs (line 704) — hashtable splatting
          -> Send-ClaudeCommand.ps1 param($InjectNormal) (line 15)
            -> Build-WorkerPrompt (reads $InjectNormal at line 245)
```

**Key detail**: When `$InjectNormal` is empty, the `if ($InjectNormal)` gate at ClaudeTui.ps1 line 678 prevents `$sendArgs['InjectNormal']` from being set. PowerShell hashtable splatting then does NOT pass `-InjectNormal`, so Send-ClaudeCommand.ps1 uses its default of `""`. This is correct — no unnecessary parameter passing, and Build-WorkerPrompt's own `if ($InjectNormal)` gate ensures no injection.

**Verdict**: PASS. Parameter is declared, correctly received, and never silently dropped.

### 3.2 Build-WorkerPrompt handles InjectNormal correctly — PASS

**Repair applied**: 20 lines added to `Build-WorkerPrompt` (lines 243–262 of Send-ClaudeCommand.ps1).

**Logic trace**:

1. **Gate**: `if ($InjectNormal)` (line 245) — zero impact when empty.
2. **Path construction**: `prompt_templates/role/$Role/normal_prompt/$InjectNormal.md` (line 246) — correct. Uses `$skillRoot` (script-level from line 24) and `$Role` (param from line 6).
3. **Missing file**: `throw "InjectNormal error: Normal prompt template '$InjectNormal' not found for role '$Role'. Expected at: $normalFile"` (line 249) — clear, actionable message.
4. **Read failure**: try/catch with throw (lines 251–255) — handles permissions, encoding, and I/O errors.
5. **Injection block**: `$injectBlock` variable (lines 256–261) with `INJECTED NORMAL PROMPT:` marker and raw content.
6. **Empty case**: `$injectBlock = ""` (line 244) — output identical to pre-fix behavior.

**Preflight redundancy**: `Assert-SendPreflight` in ClaudeTui.ps1 (lines 598–608) already validates template existence + readability **before** any manager state mutation. Send-ClaudeCommand.ps1's own check is defense-in-depth. If the file disappears between preflight and injection (TOCTOU), the Send-ClaudeCommand.ps1 throw is caught by `_DoLaunch`'s try/finally, resulting in a clear error without zombie entry.

**Write-Host diagnostic**: Line 247 logs `[INJECT-NORMAL] Loading: <path>` to the information stream (PowerShell 5+), not stdout — does not interfere with launch JSON parsing in ClaudeTui.ps1.

**Verdict**: PASS. Gating, path construction, error handling, and no-op case all correct.

### 3.3 Injection position does not break completion contract or TASK — PASS

**Placement in `return @"..."@` here-string** (lines 264–275):

```
$header
Automated pipeline. No confirmation needed...

MANDATORY COMPLETION — after the task, do these steps:
1. Write a summary ... to: $resultPath
2. Call: powershell.exe ... -File "$completeScriptPath" ...
If task failed: add -State failed -ExitCode 1...

$injectBlock                           <-- INJECTION POINT
TASK:
$UserPrompt
```

**Analysis**:
- The `MANDATORY COMPLETION` block is complete and uninterrupted — the worker can always see how to signal completion.
- The `TASK:` marker is intact — the orchestrator's task is always the final block.
- The injected normal prompt sits between them as role-specific directives — semantically appropriate.
- No `Write-Host` or mutable state inside the prompt builder — purely declarative.

**Verdict**: PASS. Injection position is optimal: after contract, before task.

### 3.4 pending_task_error displayed correctly — PASS

**Repair applied**: Two changes in ClaudeTui.ps1.

**A. Normalize-AgentEntry** (line 219):
```powershell
Ensure-EntryProp $Entry "pending_task_error" $null
```
Ensures the property exists on all agent entries — consistent with `current_task`, `pending_task`, etc. Prevents null-access errors.

**B. Invoke-AgentDetail** (lines 902–906):
```powershell
if ($e.PSObject.Properties["pending_task_error"] -and $e.pending_task_error) {
    Write-Host "  --- Pending Task Error ---"
    Write-Host "  $($e.pending_task_error)"
    Write-Host ""
}
```

**Guard semantics**: `PSObject.Properties["pending_task_error"]` protects against legacy entries without the property. `$e.pending_task_error` ensures content is non-empty. Only displays when a real error was recorded by the auto-continue catch handler.

**Read-only**: No state mutation, no side effects.

**Verdict**: PASS. Property normalized, display guarded, read-only.

### 3.5 Parser.ParseFile 0 errors, Mock-SendFixture 19/19 pass — PASS

**AST validation**: Both scripts parse with 0 errors.

**Fixture suite**: All 19 tests pass, including the 5 new boundary-repair tests (15–19). No test regressions.

**Verdict**: PASS.

### 3.6 Security, compatibility, here-string risks — PASS

**Here-string expansion**: PowerShell's `@"..."@` performs one pass of variable expansion. The `$injectBlock` variable (containing raw file content) is interpolated into the outer `return @"... "@` here-string. Any `$` characters in the normal_prompt .md file are preserved as literal text — no re-expansion occurs.

**Prompt delivery path**: The prompt is written to a `.txt` file (`Set-Content`, line 409), then read by the runner script (`Get-Content`, line 532). No live here-string evaluation in the runner — the content is simply read from disk and passed to `claude`.

**Encoding**: All file I/O uses `-Encoding UTF8`. Unicode preserved.

**Minor note**: If a normal_prompt .md file contains `"@` at the start of a line, it would prematurely terminate the `$injectBlock` here-string, causing a PowerShell parse error. In practice, this pattern is unlikely in markdown files.

**Verdict**: PASS. No injection risks, no privilege escalation, no arbitrary code execution.

---

## 4. Gap Analysis

### 4.1 Pre-existing gaps (NOT introduced by the repair)

| Gap | Severity | Status |
|-----|----------|--------|
| Crash between _DoLaunch save and pending_task clear | Low | Not in scope |
| Orphan process window (unparseable launch JSON) | Low | Not in scope |
| No runtime/behavioral test for auto-continue catch path | Low | Not in scope |

### 4.2 Minor observations (non-blocking)

1. **TOCTOU coverage**: Between preflight and injection, if normal_prompt file is deleted, Send-ClaudeCommand.ps1 throws correctly. Defense-in-depth is adequate.

2. **Write-Host vs stdout**: The `[INJECT-NORMAL] Loading:` diagnostic uses `Write-Host` (information stream in PS5+), which does not mix with launch JSON on stdout.

3. **Consistent naming**: `-InjectNormal` is used throughout the entire chain — reduces cognitive load.

---

## 5. Compliance Matrix

| # | Criterion | Status |
|---|-----------|--------|
| 1 | Send-ClaudeCommand declares InjectNormal param | PASS |
| 2 | Manager params not silently lost | PASS |
| 3 | Build-WorkerPrompt reads correct normal_prompt file | PASS |
| 4 | Empty InjectNormal -> no injection | PASS |
| 5 | Missing normal_prompt -> clear throw | PASS |
| 6 | Read failure -> clear throw | PASS |
| 7 | Injection position does not break completion contract | PASS |
| 8 | TASK: marker intact after injection | PASS |
| 9 | pending_task_error normalized | PASS |
| 10 | pending_task_error displayed in agent detail | PASS |
| 11 | AST 0 errors (both scripts) | PASS |
| 12 | All 19 fixture tests pass | PASS |
| 13 | No security/here-string risks | PASS |
| 14 | No compatibility issues | PASS |

---

## 6. Summary

The boundary repair correctly resolves both issues identified in the queue transaction final review:

1. **InjectNormal wiring**: The `$InjectNormal` parameter is now properly declared in `Send-ClaudeCommand.ps1`, received via hashtable splatting from the manager, and injected into the worker prompt by `Build-WorkerPrompt`. The injection is gated (empty -> no-op), validates file existence (throws on missing), and is positioned between the completion contract and the TASK: marker — structurally correct.

2. **pending_task_error visibility**: The `pending_task_error` property is now normalized in `Normalize-AgentEntry` and displayed in `Invoke-AgentDetail` with a guarded `--- Pending Task Error ---` block. The display is read-only and only appears when a real error was recorded.

All 19 source-invariant tests pass. Both scripts parse with 0 AST errors. No security, compatibility, or here-string risks were introduced.

**Recommendation**: Proceed. The repair is production-ready.
