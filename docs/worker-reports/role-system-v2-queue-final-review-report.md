# Role System v2 — Queue Transaction Final Review Report

> **Author**: role-system-v2-queue-reviewer-final-p
> **Date**: 2026-06-15 22:15 UTC+8
> **Verdict**: **CONDITIONAL PASS** — Core semantics correct; 3 noted gaps exist but none are regressions from the repair scope.

---

## 1. Scope & Method

This is a final independent review of the queue transaction repair chain (Repair 1 → Repair 2), 
verifying that the current code at `F:\AI_project\Claude_worker_ver2` satisfies the claimed 
semantics. The review is **strictly read-only**: no file mutations, no git commits, no real 
Claude launched.

### Reviewed Sources

| Source | Role |
|--------|------|
| `docs/worker-reports/role-system-v2-queue-transaction-repair-report.md` | Repair 1 claims (10 fixture tests) |
| `docs/worker-reports/role-system-v2-queue-transaction-repair-2-report.md` | Repair 2 claims (14 fixture tests) |
| `scripts/ClaudeTui.ps1` (1448 lines) | Manager CLI: Sync-DoneToManager, Invoke-SendInternal, _DoLaunch, agent display |
| `scripts/Send-ClaudeCommand.ps1` (649 lines) | Downstream launcher: prompt builder, runner generation |
| `tests/Mock-SendFixture.ps1` | 14 source-invariant static verification tests |
| `tests/Sync-DeadToFailed-Timeout-Tests.ps1` | Timeout ceiling & semantic tests |
| `docs/agents-json-schema.md` | Schema doc, Transaction Rules, InjectNormal Queue Preservation |

---

## 2. Verification Results

### 2.1 PowerShell AST Parsing — CLEAN

| File | AST Errors |
|------|-----------|
| `scripts/ClaudeTui.ps1` | 0 |
| `scripts/Send-ClaudeCommand.ps1` | 0 |

### 2.2 Mock-SendFixture (14 tests) — ALL PASS

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
```

### 2.3 Sync-DeadToFailed-Timeout Tests — ALL PASS

| Test | Result |
|------|--------|
| Static: Start-Job/Wait-Job/Remove-Job pattern present | PASS |
| Hard ceiling: timeout pattern confirmed (mock delay < 6s) | PASS |
| Semantic: dead PID → failed, $null pid | PASS |

---

## 3. Semantic Analysis — Per Review Criterion

### 3.1 ✅ InjectNormal preserved through queue + auto-continue

**Code evidence** (ClaudeTui.ps1):

- **Busy path** (line 644): `pending_task = [ordered]@{ prompt = ...; role = ...; model = ...; inject_normal = if ($InjectNormal) { $InjectNormal } else { "" } }`
- **W-branch** (line 812): same pattern verbatim.
- **Sync-DoneToManager read** (line 364): `$pendingInjectNormal = if ($pending.PSObject.Properties["inject_normal"] -and $pending.inject_normal) { $pending.inject_normal } else { "" }`
- **Auto-continue call** (line 366): `Invoke-SendInternal ... -InjectNormal $pendingInjectNormal`
- **Invoke-SendInternal param** (line 624): `[string]$InjectNormal = ""` (explicit parameter)
- **_DoLaunch param** (line 649): `param($AgentId, $Entry, $Prompt, $Role, $Model, $InjectNormal)`
- **current_task record** (line 739): `inject_normal = if ($InjectNormal) { $InjectNormal } else { "" }`

**Verdict**: ✅ PASS. InjectNormal flows from queue → pending_task → Sync-DoneToManager → Invoke-SendInternal → _DoLaunch → current_task. All 4 _DoLaunch call sites pass `-InjectNormal` explicitly. Preflight validates real InjectNormal template existence at each stage (Assert-SendPreflight is called before mutation in all paths).

### 3.2 ✅ pending_task NOT cleared before auto-continue success

**Code evidence** (ClaudeTui.ps1 lines 361-374):

The `foreach ($as in $autoStarts)` loop inside `Sync-DoneToManager`:
1. Reads `$pending = $as.entry.pending_task` (line 362)
2. Calls `Invoke-SendInternal ...` inside `try` (line 366)
3. **Only after** Invoke-SendInternal returns successfully: re-reads fresh entry from disk, **then** clears `$foundAfter.entry.pending_task = $null` (line 371), then saves (line 373)

Before this repair, the code cleared pending_task and called Save-Agents BEFORE Invoke-SendInternal, causing race condition where a failed launch would permanently lose the queued task.

**Verdict**: ✅ PASS. pending_task clearing is correctly deferred until after Invoke-SendInternal returns successfully. The re-read from disk (line 368-369) ensures the post-launch state is fresh.

### 3.3 ✅ Failed launch preserves pending_task + records pending_task_error

**Code evidence** (ClaudeTui.ps1 lines 375-388):

The `catch` block:
1. Logs `[AUTO-CONTINUE] FAILED: launch/preflight threw; pending_task preserved.` (line 376)
2. Does **NOT** clear `pending_task`
3. Re-reads agents from disk (lines 378-379)
4. Adds/updates `pending_task_error` property with timestamp + error message (lines 381-386)
5. Saves agents.json with pending_task retained + error diagnostic added

The old agent status (["finished","ready"]) is NOT overwritten — the catch block sets only `pending_task_error` and `updated_at`.

**Verdict**: ✅ PASS. Failure paths preserve pending_task. Error diagnostic is recorded. Status is not corrupted.

### 3.4 ✅ New agent entry avoids zombie creation

**Code evidence** (ClaudeTui.ps1):

- **Invoke-Send new-agent** (lines 765-770): `$entry = New-AgentEntry; $Agents[$key] = $entry; _DoLaunch ...` — NO Save-Agents between `New-AgentEntry` and `_DoLaunch`.
- **Invoke-SendInternal new-agent** (lines 629-634): Same pattern — entry created in-memory, `_DoLaunch` called, only saved inside `_DoLaunch` on success (line 745).
- **_DoLaunch Save-Agents** (lines 743-745): `$Agents = Read-Agents; $Agents[$Entry.internal_id] = $Entry; Save-Agents` — single atomic save after all fields set.
- **Existing-entry mutation deferred** (Invoke-Send): `_DoLaunch` called directly on found entry; `current_task`/`status`/`pid` set only after launch JSON parsed successfully.
- **Throw on failure** (lines 705, 710): Non-zero exit → throw; unparseable JSON → throw. No `exit` calls in error paths.

**Verdict**: ✅ PASS. No persistence before launch success. Atomic save on success. Throw ensures callers can handle errors and no partial entry persists.

**Known limitation** (documented): If Send-ClaudeCommand starts a process but launch JSON is unparseable, the OS process is orphaned (exists without agents.json entry). Minimal window, no big refactoring.

### 3.5 ⚠️ Agent display shows pending_task and inject_normal but NOT pending_task_error

**Code evidence** (ClaudeTui.ps1 lines 862-901):

`Invoke-AgentDetail`:
- Lines 891-895: `$e.current_task | ConvertTo-Json -Depth 5 | Write-Host` — shows `inject_normal`
- Lines 896-900: `$e.pending_task | ConvertTo-Json -Depth 5 | Write-Host` — shows `inject_normal`
- **Missing**: `pending_task_error` is a **top-level entry property** (not nested inside `pending_task`), and is NOT displayed anywhere.

When auto-continue fails, `pending_task_error` is written to agents.json but users running `ClaudeTui agent <id>` will not see it. The field is discoverable only by inspecting agents.json directly.

**Verdict**: ⚠️ PARTIAL. pending_task with inject_normal is visible via ConvertTo-Json. pending_task_error is NOT displayed. This limits diagnostic utility for auto-continue failures.

### 3.6 ✅ No parser errors or semantic PowerShell issues

- ClaudeTui.ps1: 0 AST parse errors
- Send-ClaudeCommand.ps1: 0 AST parse errors
- No `}function` formatting issues (verified)
- No `exit` in error paths (verified — uses `throw`)
- All 4 `_DoLaunch` calls pass `-InjectNormal` explicitly (verified, count = 4)

**Verdict**: ✅ PASS. Clean parsing. No semantic PowerShell errors.

### 3.7 ⚠️ Test coverage: adequate for static, missing runtime

**What is covered** (14 + 3 tests):
- Source-invariant pattern checks (regex on source)
- Static analysis of job/timeout patterns
- Behavioral timeout ceiling
- PID semantic test

**What is NOT covered**:
- **No runtime/behavioral test for the auto-continue catch path**: The catch block is only verified by regex matching; no test actually triggers a launch failure and verifies pending_task preservation + pending_task_error recording.
- **No test for InjectNormal prompt injection**: The actual flow of InjectNormal from pending_task → _DoLaunch → Send-ClaudeCommand.ps1 → Claude prompt is not tested. The static test only verifies parameter passing at the manager level.
- **No test for pending_task_error display visibility**: Invoke-AgentDetail output is not verified to include pending_task_error.
- **No integration/fixture test that simulates Sync-DoneToManager end-to-end**: All tests are source-invariant or standalone; the interaction between Sync-DoneToManager and Invoke-SendInternal (with _DoLaunch) is not exercised.
- **No test for the crash-recovery edge case** (see Finding 3 below).

**Verdict**: ⚠️ ADEQUATE FOR SCOPE, but significant runtime gaps remain. Given the repair scope (manager-level queue transaction fixes), the 14 static tests adequately cover the claimed semantics. However, a `mock-Send-ClaudeCommand.ps1` fixture that simulates success/failure would add confidence for the auto-continue catch path.

---

## 4. Additional Findings (Beyond Repair Scope)

### Finding 1: InjectNormal silently lost at Send-ClaudeCommand.ps1 boundary

**Severity**: Medium (not a regression; pre-existing architecture limitation)

`Send-ClaudeCommand.ps1` does **not** declare a `$InjectNormal` parameter, nor does it reference `$args`. When `_DoLaunch` splats `-InjectNormal SomeName` to `Send-ClaudeCommand.ps1`, the value is placed in the script-level `$args` and silently discarded.

**Impact**: The `InjectNormal` feature is correctly *tracked* (in pending_task, current_task, validated via Assert-SendPreflight) but the actual normal prompt content is never *injected* into the Claude worker prompt. The `Build-WorkerPrompt` function in Send-ClaudeCommand.ps1 (lines 232-253) reads only `header.md` and concatenates `$Prompt` — there is no normal_prompt injection logic.

**Recommendation**: Wire InjectNormal into `Build-WorkerPrompt` in Send-ClaudeCommand.ps1. Read the template from `prompt_templates/role/<role>/normal_prompt/<name>.md` and append it to the prompt.

### Finding 2: pending_task_error invisible in `agent detail` display

**Severity**: Low

When auto-continue fails, `pending_task_error` is recorded on the agent entry (top-level property). However, `Invoke-AgentDetail` only shows `current_task` and `pending_task` via ConvertTo-Json. The `pending_task_error` field is never displayed.

**Recommendation**: Add a display block for `pending_task_error` in `Invoke-AgentDetail`:
```powershell
if ($e.pending_task_error) {
    Write-Host "  --- Pending Task Error ---"
    Write-Host "  $($e.pending_task_error)"
    Write-Host ""
}
```

### Finding 3: Crash between _DoLaunch save and pending_task clear may cause task re-execution

**Severity**: Low (crash-only window)

If the process crashes between `_DoLaunch`'s `Save-Agents` (line 745, which sets status=["running"] but does NOT clear pending_task) and `Sync-DoneToManager`'s try-block clear (lines 371-373), on restart the agent would have:
- status=["running"] (from _DoLaunch)
- pending_task still set (never cleared)

When this agent finishes, `Sync-DoneToManager` would find it with pending_task and auto-continue again, resulting in **duplicate execution** of the same queued task.

**Recommendation**: Consider a `pending_task_auto_continued_at` timestamp or a deduplication guard. In practice, the window is very narrow (two consecutive `Save-Agents` calls within the same process) and only relevant during a hard crash.

### Finding 4: Orphan process window (already documented)

If `Send-ClaudeCommand` starts a process but the launch JSON cannot be parsed, the OS process runs without an agents.json entry ("zombie"). This is a known limitation documented in the schema doc.

---

## 5. Compliance Matrix

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| 1 | InjectNormal preserved queue→auto-continue | ✅ PASS | Lines 364, 366, 624, 644, 649, 812 |
| 2 | pending_task cleared AFTER launch success | ✅ PASS | Lines 366→371 (try block ordering) |
| 3 | Launch failure preserves pending_task | ✅ PASS | Lines 375-388 (catch block: no clear) |
| 4 | pending_task_error recorded on failure | ✅ PASS | Lines 381-386 |
| 5 | No zombie on new-agent launch failure | ✅ PASS | No Save-Agents before _DoLaunch |
| 6 | Agent display shows pending_task content | ✅ PASS | Line 898: ConvertTo-Json |
| 7 | Agent display shows pending_task_error | ⚠️ GAP | Not displayed |
| 8 | InjectNormal wired into actual prompt | ⚠️ GAP | Lost at Send-ClaudeCommand boundary |
| 9 | AST 0 errors (ClaudeTui.ps1) | ✅ PASS | Verified |
| 10 | AST 0 errors (Send-ClaudeCommand.ps1) | ✅ PASS | Verified |
| 11 | All fixture tests pass | ✅ PASS | 14/14 |
| 12 | Tests cover runtime behaviors | ⚠️ PARTIAL | Static only; no mock-launch fixtures |
| 13 | No }function formatting | ✅ PASS | Verified |
| 14 | Schema doc synchronized | ✅ PASS | inject_normal in schema |

---

## 6. Summary

The two repairs correctly resolve the stated M1 (InjectNormal queue preservation) and M2 (launch transaction / zombie reduction) objectives at the **manager level** (ClaudeTui.ps1). The core queue transaction semantics — inject_normal preservation, deferred pending_task clearing, failure recovery with error diagnostics, and anti-zombie persistence — are all correctly implemented and verified by 14 source-invariant tests.

Three gaps are noted but none are regressions from the repair scope:
1. InjectNormal is tracked correctly in the manager, but not wired into the actual prompt builder (Send-ClaudeCommand.ps1) — this is a pre-existing architectural gap, not introduced by the repairs.
2. `pending_task_error` is recorded on failure but not displayed in `agent detail` — minor diagnostic UX gap.
3. A narrow crash window exists between _DoLaunch save and pending_task clear — low probability, documented.

Test coverage is adequate for the repair scope (static verification of code patterns) but would benefit from mock-launch fixtures that exercise the auto-continue success/failure paths end-to-end.

---

## 7. Recommendations

1. **Wire InjectNormal into Send-ClaudeCommand.ps1** (priority: Medium) — Add `$InjectNormal` parameter, read template from `normal_prompt/<name>.md`, append to `Build-WorkerPrompt`.
2. **Display pending_task_error in Invoke-AgentDetail** (priority: Low) — Add a display block for the `pending_task_error` property.
3. **Add runtime mock tests** (priority: Low) — Create a mock `Send-ClaudeCommand.ps1` fixture that can simulate both success and failure, and verify the auto-continue try/catch behavior with actual function calls.
4. **Consider deduplication guard for pending_task** (priority: Low) — Add a `pending_task_command_id` or timestamp to prevent double-execution in crash-recovery scenarios.
