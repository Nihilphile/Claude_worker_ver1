# TUI Argument Fidelity Repair — Report 2

> **Author**: role-system-v2-tui-coder-p
> **Date**: 2026-06-15 08:16–08:25 UTC+8
> **Verdict**: **PASS** — Review FAIL closed, regression repaired, 8/8 checks pass

---

## Review Finding: FAIL

The prior fix (report 1) used  in the TUI runner
template. This is a **critical argument fidelity regression**.

### Root Cause

PowerShell  does NOT preserve array fidelity:

1. PowerShell converts the array to a single space-joined string
2.  passes that string to the child process
3. The child re-parses the string, splitting on spaces
4. Every multi-word argument (workspace path, prompt text, system-prompt-file path)
   is shattered into separate words

### Evidence

Test with 7-element args array containing spaced paths and natural-language prompt:

| Method | Args Received | Fidelity |
|--------|:---:|:---:|
| **Start-Process -ArgumentList** | **22** (completely wrong) | FAIL |
| **Call operator with splatting** | **7** (correct) | PASS |

 → Start-Process: 4 args; call operator: 1 arg ✅

---

## Repair Applied

### scripts/Send-ClaudeCommand.ps1 — TUI Template (lines 560-566)

**Before (BROKEN):**
Windows PowerShell
°æȨËùÓУ¨C£© Microsoft Corporation¡£±£ÁôËùÓÐȨÀû¡£

°²װ×îÐµÄ PowerShell£¬Á˽âÐ¹¦Äܺ͸Ľø£¡https://aka.ms/PSWindows

PS F:\AI_project\Claude_worker_ver2> 

**After (FIXED):**
Windows PowerShell
Copyright (C) Microsoft Corporation. All rights reserved.

Install the latest PowerShell for new features and improvements! https://aka.ms/PSWindows

PS F:\AI_project\Claude_worker_ver2> 

### Design Rationale

| Mechanism | Purpose |
|-----------|---------|
|  (call operator) | Invokes claude as a native command |
|  (splatting) | Expands array to individual argv elements — each preserved exactly |
|  | Native PowerShell stderr redirection to log file; stream 1 (stdout) untouched |
|  | Captures native command exit code |

**No pipeline.** Stdin, stdout, stderr stream 1 all remain connected to the console.
Only stream 2 (stderr) is redirected to file. TUI interactivity is fully preserved.

### Preservation of Prior B7 Fixes

All fixes from report 1 are retained:
-  defined (line 524)
-  defined (line 526)
-  resolved outside if-block (line 571)
- done.json fallback: sidFile → curSessionId (line 575)
-  field in done.json (line 575)
- Enhanced transcript: exit_code, stderr_log, session_id, done_at (lines 578-582)

---

## Verification Results

### 1.  on  — PASS


### 2. Extracted TUI Template Pattern Check — PASS


### 3. Extracted TUI Template  — PASS


### 4. Call Operator Argument Fidelity — PASS

Receiver script test with 7 args (spaced paths, quotes, multi-line prompt, Unicode):

All 7 args preserved exactly. No splitting on spaces.

### 5. Stderr Capture + LASTEXITCODE — PASS

Stderr captured to log file; stdout visible on console; exit code captured.

### 6. No Start-Process References in Core Docs — PASS
Zero references to , , or  in
 and  (only in prior worker reports, which document past state).

### 7.  — PASS
No whitespace errors (only pre-existing LF/CRLF warnings).

### 8. No Unwanted Changes — PASS
-  unchanged
- Role content unchanged
- No git commit
- No 

---

## Files Modified (this round)



## Files Unchanged from Report 1



---

## Review Closure

| Finding | Status |
|---------|:------:|
| Start-Process -ArgumentList corrupts TUI args | **FIXED** — replaced with  |
| Need call operator for argument fidelity | **DONE** |
| Need native stderr redirect (2>>) not redirect pipeline | **DONE** |
| Need LASTEXITCODE not proc.ExitCode | **DONE** |
| Verify with safe local receiver script | **DONE** |
| AST parse on full Send-ClaudeCommand.ps1 (real 0) | **DONE** |
| AST parse on generated TUI runner template | **DONE** |
| Docs must not claim Start-Process approach | **DONE** (no such claims exist) |

**Verdict: PASS — All review FAIL items closed.**
