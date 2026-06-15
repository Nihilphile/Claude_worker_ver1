# Role System v2 — Queue Transaction Repair 2 Report (Reviewer Follow-up)

> **Author**: role-system-v2-queue-coder-p
> **Date**: 2026-06-15 08:16 UTC+8
> **Verdict**: **FIXED** — All 14 fixture verifications pass; AST 0 errors; git diff --check clean

---

## Context

This is a follow-up repair addressing 5 reviewer findings against the initial B6 M1/M2 repair:

1. Auto-continue race condition (pending_task cleared before launch success)
2. Invoke-AgentDetail pending_task display missing role/model/inject_normal
3. Missing newline between `}` and `function`
4. tests/ has unused mock scripts + dead backup logic
5. Orphan process window remains a known limitation

### Scope (per controller ruling)

| Item | Status |
|------|--------|
| Sync-DoneToManager defers pending_task clear until launch success | Done |
| Auto-continue failure preserves pending_task + records error | Done |
| Invoke-AgentDetail pending_task shown via ConvertTo-Json | Done |
| Format: no }function merging | Done |
| tests/ cleaned; Mock-SendFixture source-invariant only | Done |
| Orphan window kept as known limitation | Complied |
| No real Claude, no TUI runner changes, no git commit | Complied |

---

## Fix 1: Sync-DoneToManager Auto-Continue Race Condition

**Before (bug)**:
```powershell
foreach ($as in $autoStarts) {
    $pending = $as.entry.pending_task
    $as.entry.pending_task = $null          # cleared BEFORE launch
    Save-Agents -Agents $Agents             # saved BEFORE launch
    ...
    Invoke-SendInternal ...                 # if this throws, pending_task is GONE
}
```

**After (fixed)**:
```powershell
foreach ($as in $autoStarts) {
    $pending = $as.entry.pending_task
    Write-Host "[AUTO-CONTINUE] Queued task ..."
    $pendingInjectNormal = ...
    try {
        Invoke-SendInternal ...
        # Only AFTER success: re-read, clear pending_task, save
        Invalidate-Cache; $Agents = Read-Agents
        $foundAfter = Find-ActiveAgent ...
        if ($foundAfter) {
            $foundAfter.entry.pending_task = $null
            $foundAfter.entry.updated_at = (Get-Date).ToString("o")
            Save-Agents -Agents $Agents
        }
    } catch {
        Write-Host "[AUTO-CONTINUE] FAILED: launch/preflight threw; pending_task preserved. Error: $_"
        # Re-read, record diagnostic, do NOT clear pending_task
        Invalidate-Cache; $Agents = Read-Agents
        $foundAfter = Find-ActiveAgent ...
        if ($foundAfter) {
            $foundAfter.entry | Add-Member -NotePropertyName "pending_task_error" ...
            $foundAfter.entry.pending_task_error = "Auto-continue failed at ..."
            $foundAfter.entry.updated_at = (Get-Date).ToString("o")
            Save-Agents -Agents $Agents
        }
    }
}
```

Key behavior changes:
- pending_task NOT cleared before Invoke-SendInternal.
- On success: re-read fresh entry from disk, THEN clear pending_task and save.
- On failure (catch): pending_task preserved. Error recorded in `pending_task_error` field. Old agent status (finished/ready) not overwritten with fake "running".
- `Invalidate-Cache` + `Read-Agents` ensures the post-launch read is fresh (Invoke-SendInternal internally writes agents.json).

---

## Fix 2: Invoke-AgentDetail Pending Task Display

**Before**:
```powershell
if ($e.pending_task) {
    Write-Host "  --- Pending Task ---"
    Write-Host "  Prompt: $($e.pending_task.prompt)"
    Write-Host ""
}
```

**After**:
```powershell
if ($e.pending_task) {
    Write-Host "  --- Pending Task ---"
    $e.pending_task | ConvertTo-Json -Depth 5 | Write-Host
    Write-Host ""
}
```

Now `agent detail <id>` shows the full pending_task including `role`, `model`, and `inject_normal`.

---

## Fix 3: Missing Newline Formatting

**Before** (line 242):
```powershell
}function Capture-FreshSessionUuid {
```

**After**:
```powershell
}

function Capture-FreshSessionUuid {
```

Verified: `grep -n '}function' ClaudeTui.ps1` returns no matches.

---

## Fix 4: tests/ Cleanup

- **Removed** 3 unused mock scripts: `mock-fail-nonzero.ps1`, `mock-fail-parse.ps1`, `mock-success.ps1`
- **Rewrote** `Mock-SendFixture.ps1` as a pure source-invariant test:
  - No `Copy-Item agents.json` / `Restore-Agents` dead backup logic
  - No `KeepArtifacts` param
  - Reads `ClaudeTui.ps1` source and `agents-json-schema.md` to verify code patterns
  - Does NOT execute any manager functions, mutate agents.json, or start processes
  - 14 tests covering all acceptance criteria

---

## Fix 5: Orphan Process Window

Kept as a known limitation. Documented in `agents-json-schema.md` Transaction Rules section. If `Send-ClaudeCommand` starts a process but the launch JSON cannot be parsed, the process is orphaned (exists in OS without agents.json entry). Minimal window — no big refactoring.

---

## Files Changed

| File | Change |
|------|--------|
| `scripts/ClaudeTui.ps1` | 3 edits: Sync-DoneToManager try/catch, Invoke-AgentDetail ConvertTo-Json, }function newline |
| `tests/Mock-SendFixture.ps1` | Rewritten: no dead backup, no mock execution, 14 source-invariant tests |
| `tests/mock-fail-nonzero.ps1` | **Removed** |
| `tests/mock-fail-parse.ps1` | **Removed** |
| `tests/mock-success.ps1` | **Removed** |
| `docs/worker-reports/role-system-v2-queue-transaction-repair-2-report.md` | **New** |

---

## Verification Results

### #1: PowerShell AST — 0 parse errors

### #2: git diff --check — clean (CRLF warnings only)

### #3: Source-Invariant Fixture — ALL 14 PASS

| # | Test | Result |
|---|------|--------|
| 1 | Invoke-Send new-agent: no Save-Agents before _DoLaunch | PASS |
| 2 | Invoke-SendInternal new-agent: no Save-Agents before _DoLaunch | PASS |
| 3 | _DoLaunch throw (not exit) for failures | PASS |
| 4 | _DoLaunch single atomic Save-Agents | PASS |
| 5 | pending_task includes inject_normal | PASS |
| 6 | Sync-DoneToManager reads/passes inject_normal | PASS |
| 7 | Auto-continue defers pending_task clear until AFTER launch success | PASS |
| 8 | Auto-continue catch preserves pending_task + records error | PASS |
| 9 | Invoke-AgentDetail uses ConvertTo-Json for pending_task | PASS |
| 10 | No unused mock scripts in tests/ | PASS |
| 11 | No }function missing-newline | PASS |
| 12 | Explicit InjectNormal parameter flow | PASS |
| 13 | current_task records inject_normal | PASS |
| 14 | agents-json-schema.md synchronized | PASS |

---

## Compliance with Acceptance Criteria

| # | Criterion | Status |
|---|-----------|--------|
| 1 | AST 0 errors | PASS |
| 2 | Fixture: auto-continue failure preserves pending_task with inject_normal | PASS (tests 7,8) |
| 3 | Fixture: success clears pending_task | PASS (test 7) |
| 4 | Display includes inject_normal | PASS (test 9) |
| 5 | No unused mock files | PASS (test 10) |
| 6 | git diff --check | PASS |
| 7 | No real Claude, no TUI runner changes, no git commit | Complied |

---

## Verdict: FIXED

All 5 reviewer findings resolved. 14/14 fixture tests pass. AST clean. Git diff clean.