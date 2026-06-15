# Role System v2 Targeted Smoke Report

**Date**: 2026-06-15  
**Smoke Runner**: role-system-v2-targeted-smoke-p  
**Workspace**: F:\AI_project\Claude_worker_ver2  
**Agent ID Prefix**: v2-targeted-20260615  

---

## 1. Static Baseline

### 1.1 Parser.ParseFile Syntax Check

| Script | Result |
|--------|--------|
| scripts/ClaudeTui.ps1 | PASS — 0 parse errors |
| scripts/Send-ClaudeCommand.ps1 | PASS — 0 parse errors |

### 1.2 Mock-SendFixture.ps1

**Test Count**: 19 tests  
**Result**: ALL PASS (0 failures)

Coverage:
- Transaction atomicity (no Save-Agents before _DoLaunch)
- throw vs exit for launch failures
- Single atomic Save-Agents in _DoLaunch
- pending_task inject_normal preservation
- Auto-continue inject_normal flow
- pending_task_error normalization and display
- Schema doc synchronization
- Send-ClaudeCommand InjectNormal parameter chain
- Build-WorkerPrompt injection logic

### 1.3 Sync-DeadToFailed-Timeout-Tests.ps1

**Result**: ALL TESTS PASSED

- Test 1: Static analysis — Start-Job/Wait-Job/Remove-Job pattern present
- Test 2: Behavioural — Hard timeout ceiling confirmed (mock delay cut off at 3s, elapsed=3s < 6s ceiling)
- Test 3: Semantic — Dead PID 99999999 correctly transitions to `failed`, pid set to $null

---

## 2. InjectNormal Real Chain Test

### 2.1 Command Summary

| Field | Value |
|-------|-------|
| CLI | ClaudeTui.ps1 send |
| Agent ID | v2-targeted-20260615-001 |
| Command ID | 20260615-223616-430 |
| Role | test |
| InjectNormal | strict-json-evidence |
| Mode | p |
| FreshSession | yes |
| Session UUID | a15b91e0-3213-4606-99a9-8a1078575db1 |
| PID | 27372 |
| Launched At | 2026-06-15T22:36:16 |

### 2.2 State Timeline

| Time | State | Method |
|------|-------|--------|
| 22:36:16 | launched | ClaudeTui.ps1 send |
| 22:36:16+ | → running | Update-WorkerState --running |
| 22:36:xx | → coding | Update-WorkerState --coding |
| 22:36:xx | → reviewing | Update-WorkerState --reviewing |
| 22:36:49 | → exit (confirmed=true) | Update-WorkerState --exit -Confirm |
| 22:36:49 | → finishing | Manager Sync-ReadState |
| 22:36:49-54 | grace period | Manager Sync-KillPending (5s) |
| 22:36:56 | → finished, ready | Manager KillPending cleanup |
| 22:36:56 | Worker killed (PID 27372) | Manager |

### 2.3 JSON Evidence File

- **Path**: `F:\AI_project\Claude_worker_ver2\temp_targeted_smoke_ws\evidence.json`
- **Content**:
```json
{
  "normal_marker": "V2_TEST_NORMAL_JSON_D4B7",
  "smoke_agent": "v2-targeted-20260615-001",
  "test_time": "2026-06-15T22:36:16"
}
```
- **Validation**: `normal_marker` field present with exact value `V2_TEST_NORMAL_JSON_D4B7` ✅

### 2.4 InjectNormal Injection Verification

- Marker `INJECTED NORMAL PROMPT` found in prompt file ✅
- Template marker `V2_TEST_NORMAL_JSON_D4B7` propagated from template to prompt ✅
- `current_task.inject_normal` = `"strict-json-evidence"` in agents.json ✅

### 2.5 Verdict

**PASS** — The full InjectNormal chain works correctly.

---

## 3. Missing Normal Template Rejection

### 3.1 Command

```
ClaudeTui.ps1 send v2-targeted-20260615-002 -Prompt "test missing template" 
  -Role test -InjectNormal nonexistent-fake-template -Mode p -FreshSession
```

### 3.2 Result

```
Rejected: Normal prompt template 'nonexistent-fake-template' not found for role 'test'.
```

### 3.3 Zombie Check

Agent `v2-targeted-20260615-002` NOT present in agents list ✅

### 3.4 Verdict

**PASS** — Preflight correctly rejected nonexistent template without creating agent.

---

## 4. pending_task_error Display

### 4.1 Verification Method

Static source analysis via Mock-SendFixture.ps1 tests 18 and 19:
- Test 18: `Invoke-AgentDetail` displays `--- Pending Task Error ---` section header ✅
- Test 19: `Normalize-AgentEntry` normalizes `pending_task_error` ✅

### 4.2 Verdict

**PASS**

---

## 5. Sync Dead Timeout

### 5.1 Verification Method

Executed `tests/Sync-DeadToFailed-Timeout-Tests.ps1` — ALL TESTS PASSED.

### 5.2 Verdict

**PASS**

---

## 6. Overall Verdict

| # | Test Area | Verdict |
|---|-----------|---------|
| 1 | Static Baseline (ParseFile, Mock-SendFixture, Sync-DeadToFailed) | ✅ ALL PASS |
| 2 | InjectNormal Real Chain (v2-targeted-20260615-001) | ✅ PASS |
| 3 | Missing Normal Template Rejection | ✅ PASS |
| 4 | pending_task_error Display (static) | ✅ PASS |
| 5 | Sync Dead Timeout (test script) | ✅ PASS |

**OVERALL**: **ALL TESTS PASSED** — 0 failures

---

## 7. Residual Risks

1. **done.json not written**: Worker v2-targeted-20260615-001 was killed during grace period. result.md was written but done.json was not found. State-driven cleanup handled this correctly.

2. **Single-worker test**: Only one real worker launched. Concurrency not tested.

3. **Agent cleanup**: evidence.json remains in temp workspace. Should be cleaned separately. *(Post-run: temp workspace `temp_targeted_smoke_ws` has been deleted by master.)*

4. **Pre-existing agents**: Three non-smoke agents in running state from other runs — not touched.

---

## 8. Artifacts

| Artifact | Path |
|----------|------|
| Report | docs/worker-reports/role-system-v2-targeted-smoke-report.md |
| Evidence JSON | temp_targeted_smoke_ws/evidence.json |
| Agent Store | store/v2-targeted-20260615-001/ |
| Agent Run | run/v2-targeted-20260615-001/ |
| Result.md | store/v2-targeted-20260615-001/results/20260615-223616-430.result.md |
| State File | run/v2-targeted-20260615-001/.20260615-223616-430.state |
| Prompt File | run/v2-targeted-20260615-001/run-command-20260615-223616-430.prompt.txt |

---

## 9. Post-Run Cleanup Note

**All smoke artifacts have been cleaned up since the original test execution:**

- `temp_targeted_smoke_ws/` (including `evidence.json`) — deleted by master post-run
- `store/v2-targeted-20260615-001/` — soft-deleted (agent removed from active state)
- `run/v2-targeted-20260615-001/` — soft-deleted (run directory cleaned)

The artifact paths listed in Section 8 are preserved above as historical evidence of what existed at test time; **none of these directories remain on disk**.
