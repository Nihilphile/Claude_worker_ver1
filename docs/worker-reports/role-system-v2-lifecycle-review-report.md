# Role-System v2 — Lifecycle Fix Independent Review Report

**Date**: 2026-06-15 22:00 UTC  
**Reviewer**: role-system-v2-lifecycle-reviewer-p  
**Mode**: p (pipeline, fresh session, read-only)  
**Scope**: Review of two latest lifecycle fixes in F:\AI_project\Claude_worker_ver2

---

## Overview

This review examines two independent fixes:
1. **TUI runner template here-string repair** (`role-system-v2-tui-resume-observability-repair-3-report.md`)
2. **Sync-DeadToFailed zombie-PID timeout repair** (`role-system-v2-sync-dead-timeout-repair-report.md`)

Review methodology:
- Static analysis via `[System.Management.Automation.Language.Parser]::ParseFile`
- Execution of existing test suites (no real Claude/manager state mutations)
- Cross-reference: report claims vs actual code
- Classification of tests/ directory artifacts

---

## 1. TUI Runner Template Here-String Repair

### 1.1 Parser Verdict: PASS

`scripts/Send-ClaudeCommand.ps1` → **0 parser errors** (confirmed via `Parser.ParseFile`).

### 1.2 Here-String Nesting: FIXED

Prior to the repair, lines 578–583 contained a nested `@"... "@` here-string inside the expandable `$tuiTemplate = @"... "@` outer here-string, causing the outer template to terminate prematurely at line 583's `"@`.

Post-repair, the transcript block (lines 578–584) uses:
```powershell
$transcriptLines = [System.Collections.Generic.List[string]]::new()
$transcriptLines.Add("exit_code=$exit")
$transcriptLines.Add("stderr_log=$stderrLog")
$transcriptLines.Add("session_id=$sid")
$transcriptLines.Add("done_at=$(Get-Date -Format 'o')")
$transcriptLines | Out-File -LiteralPath "$transcriptPath" -Encoding UTF8
```

**Verification**: Grep for `@"` and `"@` within the TUI template boundaries (lines 508–585):
- Only `$tuiTemplate = @"` at line 508 (opener) and `"@` at line 585 (closer).
- **Zero** nested here-string terminators. ✅

The p-mode template (`$pTemplate`, lines 589–646) also has **zero** nested here-strings. ✅

### 1.3 Call Operator + Splatting: PRESERVED

Line 565: `& claude @fullArgs 2>> $stderrLog`

- `&` call operator preserved ✅
- `@fullArgs` splatting preserved (no degradation to `Start-Process -ArgumentList`) ✅
- Each array element → exactly one argv, protecting paths with spaces ✅

### 1.4 Stderr Observability

| Artifact | Location | Status |
|----------|----------|--------|
| stderr log file | `$logsDir/$commandId.stderr.log` (line 526) | ✅ |
| stderr redirect | `2>> $stderrLog` (line 565) | ✅ |
| done.json fallback | `stderr_log=$stderrLog` (line 575) | ✅ |
| transcript log | `stderr_log=$stderrLog` (line 581) | ✅ |
| stderr leak at repo root | (none) | ✅ confirmed absent |

### 1.5 Session UUID and done.json

- `$sidFile` defined at line 524 (inside logsDir, `.claude-sid.txt`)
- `$sid` resolved at runner runtime via sidFile with fallback to `$curSessionId` (line 571)
- done.json fallback includes session_id (line 575)
- transcript includes session_id (line 582)

✅ All required observability fields present.

### 1.6 Cosmetic Issue: Indentation Inconsistency

Lines 558–559 have extra leading whitespace compared to surrounding template lines:
```powershell
        # Append system prompt (runtime contract, compression-resistant)
        if ("$systemPromptPath" -ne "") { `$fullArgs += @("--system-prompt-file", "$systemPromptPath") }
```

This propagates into generated runners (visible in both `generated-runner-test.ps1` and `generated-runner-v2.ps1`). **Not a functional bug** — the generated PowerShell is syntactically valid regardless of indentation. Low priority cosmetic cleanup.

---

## 2. Sync-DeadToFailed Zombie-PID Timeout Repair

### 2.1 Parser Verdict: PASS

`scripts/ClaudeTui.ps1` → **0 parser errors** (confirmed via `Parser.ParseFile`).

### 2.2 3-Second Hard Timeout: CONFIRMED

`Sync-DeadToFailed` (line 304–331) now wraps `Get-Process` in a background job with hard 3-second timeout:

```powershell
$procJob = Start-Job -ScriptBlock { param($p) Get-Process -Id $p -ErrorAction SilentlyContinue } -ArgumentList ([int]$pidVal)
$proc = $null
if (Wait-Job $procJob -Timeout 3) { $proc = Receive-Job $procJob }
Remove-Job $procJob -Force -ErrorAction SilentlyContinue
```

**Key properties**:
| Property | Value |
|----------|-------|
| Timeout mechanism | `Wait-Job -Timeout 3` (seconds) |
| Hard ceiling | 3.0 seconds per PID |
| Job cleanup | `Remove-Job -Force -ErrorAction SilentlyContinue` |
| On timeout | `$proc` remains `$null` → entry marked `failed` |

Behavioral test confirmed: a 30-second `Start-Sleep` mock job was cut off at **3.0 seconds** (elapsed < 6s guard). ✅

### 2.3 Semantic Preservation: CONFIRMED

| Input Status | PID | Get-Process Result | Output | Notes |
|---|---|---|---|---|
| `running` | valid PID, alive | process found | `running` (unchanged) | Agent is alive |
| `running` | valid PID, zombie | timeout (3s) | `failed`, pid = $null | Hard ceiling hit |
| `running` | valid PID, exited | no process | `failed`, pid = $null | Process gone |
| `running` | valid PID | exception | `failed`, pid = $null | Any error → failed |
| `running` | `$null` | (skipped) | `running` (unchanged) | No PID to check |
| non-`running` | (any) | (skipped) | unchanged | Scope not widened |

✅ Semantic: Any `running` entry whose PID cannot be confirmed alive within 3 seconds → `failed`.  
✅ Scope: Non-running entries are skipped (unchanged behavior).  
✅ No silent-ignore: dead PID test (`99999999`) correctly transitions to `failed`.

### 2.4 Test Suite: ALL PASS

`tests/Sync-DeadToFailed-Timeout-Tests.ps1` — 3 tests, all passing:

| # | Test | Method | Result |
|---|------|--------|--------|
| 1 | Static analysis | Confirm `Start-Job`, `Wait-Job -Timeout`, `Remove-Job -Force` in function body | PASS |
| 2 | Hard ceiling | `Start-Sleep 30` mock → `Wait-Job -Timeout 3` → elapsed = 3.0s < 6s | PASS |
| 3 | Dead PID semantic | PID `99999999` → `failed`, `pid = $null` | PASS |

### 2.5 Residual Risks (Acknowledged)

| Risk | Severity | Mitigation | Assessment |
|------|----------|------------|------------|
| Job subsystem load (100+ concurrent agents) | Low | Typical workload < 10 running entries | Acceptable |
| False-negative under extreme system load | Low | 3s = 10-30× typical Get-Process latency | Acceptable |
| Job cleanup race (leaked PS job objects) | Very Low | Jobs are disposable, not OS processes | Acceptable |
| Bare `Get-Process` still in Send-ClaudeCommand.ps1 | Low | Those query current/just-launched PID, not scanning dead-PID table | Out of scope |

---

## 3. Report vs Code Consistency

### 3.1 TUI Repair Report (#3)

| Claim | Verification |
|-------|-------------|
| "13 parser errors → 0" | ✅ Confirmed: current `Send-ClaudeCommand.ps1` has 0 parser errors |
| "stderr file at repo root deleted" | ✅ Confirmed: no `stderr` or `stderr.log` at repo root |
| "Call operator + splatting preserved" | ✅ Confirmed: `& claude @fullArgs 2>>` at line 565 |
| "All verification checks: PASS" | ✅ All checks independently confirmed |
| **Report date: "2025-06-15"** | ⚠️ **Temporal anomaly**: workspace context is 2026. This appears to be a **date typo**. All timestamps on files and the second report are 2026. Suggest correcting to "2026-06-15". |

### 3.2 Sync-Dead Repair Report

| Claim | Verification |
|-------|-------------|
| "0 parser errors" | ✅ Confirmed: current `ClaudeTui.ps1` has 0 parser errors |
| "3 tests, all passing" | ✅ Confirmed: all 3 tests pass |
| "Diff scope: only ClaudeTui.ps1 modified" | ✅ Verified via report's diff; no unexpected file changes |
| "Get-Process in Send-ClaudeCommand.ps1 left unchanged" | ✅ Confirmed: lines 204, 213, 389 still use bare `Get-Process` (out of scope) |

---

## 4. Tests Directory Classification

| File | Type | Recommendation | Rationale |
|------|------|----------------|-----------|
| `Mock-SendFixture.ps1` | **Formal test** | KEEP | 14-test static analysis suite for ClaudeTui.ps1, comprehensive, well-structured, all pass |
| `Sync-DeadToFailed-Timeout-Tests.ps1` | **Formal test** | KEEP | 3-test validation suite for the timeout fix, all pass, directly validates the repair |
| `receiver.ps1` | **Test fixture** | KEEP | Parameter fidelity test helper, lightweight, reusable for CI |
| `stderr-stub.ps1` | **Test fixture** | KEEP | Generates known-stderr output for capture verification, reusable |
| `generated-runner-test.ps1` | **Temporary artifact** | SUGGEST REMOVAL | Generated TUI runner output (v1), used for one-time fix verification. Contains test-only paths (`F:\test\store\test-agent`). Parser.ParseFile + Mock-SendFixture provide equivalent coverage. |
| `generated-runner-v2.ps1` | **Temporary artifact** | SUGGEST REMOVAL | Generated TUI runner output (v2), same nature as above. Redundant after verification. |
| `receiver-args.txt` | **Test output log** | SUGGEST MOVE or REMOVE | Output log from `receiver.ps1`, contains test timestamps and arg dumps. Not a reusable fixture. Consider moving to `tests/outputs/` or removing. |
| `test-capture.stderr.log` | **Test output log** | SUGGEST MOVE or REMOVE | Output from `stderr-stub.ps1` test run, contains captured stderr with Unicode. Not a reusable fixture. |

---

## 5. Lightweight Read-Only Verification Results

### 5.1 Parser.ParseFile

| File | Errors |
|------|--------|
| `scripts/Send-ClaudeCommand.ps1` | **0** |
| `scripts/ClaudeTui.ps1` | **0** |

### 5.2 Test Suite Execution

| Test File | Tests | Result |
|-----------|-------|--------|
| `tests/Sync-DeadToFailed-Timeout-Tests.ps1` | 3 | ALL PASS |
| `tests/Mock-SendFixture.ps1` | 14 | ALL PASS |

### 5.3 Generated Runner Consistency

Both `generated-runner-test.ps1` and `generated-runner-v2.ps1` contain the array-based transcript writing block. Differences between them are cosmetic (comment presence and minor indentation). Both are syntactically valid generated runner scripts.

---

## 6. Overall Verdict

### Verdict: **PASS WITH RISKS**

| Fix | Verdict | Confidence |
|-----|---------|------------|
| TUI template here-string repair | **PASS** | High |
| Sync-DeadToFailed timeout repair | **PASS** | High |

### Rationale

Both fixes are **technically sound**:
- The TUI template fix eliminates the nested here-string breakage cleanly, preserving all required functionality (call operator, splatting, stderr capture, session UUID, done.json, transcript).
- The Sync-DeadToFailed fix correctly introduces a 3-second hard timeout via `Start-Job`/`Wait-Job -Timeout 3`/`Remove-Job -Force`, eliminating the multi-minute hang risk from zombie-PID `Get-Process` calls.

Parser verification (0 errors), test suites (17/17 passing), and code-report cross-referencing all align.

### Risks Carried Forward

1. **TUI repair report date typo** — "2025-06-15" should be "2026-06-15". Documentation issue only.
2. **Sync-DeadToFailed job-per-PID overhead** — each `running` agent spawns a PS job. For typical workloads (< 10 running entries) this is negligible. For 100+ concurrent agents, consider batching or caching.
3. **Cosmetic indentation** — lines 558–559 in Send-ClaudeCommand.ps1 TUI template have inconsistent indentation. Not functional, but worth cleaning up in a future formatting pass.
4. **Temporary test artifacts** — 4 files in `tests/` are temporary verification artifacts or test outputs. See §4 for removal recommendations.

### Recommended Next Steps

1. **Correct the TUI repair report date** from "2025-06-15" to "2026-06-15".
2. **Clean up temporary artifacts** from `tests/`:
   - Remove: `generated-runner-test.ps1`, `generated-runner-v2.ps1`
   - Remove or move to `tests/outputs/`: `receiver-args.txt`, `test-capture.stderr.log`
3. **Fix cosmetic indentation** at lines 558–559 of `scripts/Send-ClaudeCommand.ps1` (low priority).
4. **Monitor job subsystem** under load: if agent count grows significantly, profile Sync-DeadToFailed job overhead and consider batching multiple PID checks into a single job.

---

*End of review. No files were modified during this review.*
