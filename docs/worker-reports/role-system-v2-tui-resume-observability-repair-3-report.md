# TUI Runner Template Here-String Repair — Report #3

**Date**: 2026-06-15 20:30 UTC  
**Agent**: role-system-v2-tui-coder-r3b-tui  
**Task**: Fix PowerShell syntax breakage in `scripts/Send-ClaudeCommand.ps1` TUI runner template  
**Repo**: F:\AI_project\Claude_worker_ver2

---

## 1. Root Cause

The TUI runner template (`$tuiTemplate = @"` at line 508) is an **expandable here-string**.  
Inside it, lines 578–583 embedded another expandable here-string:

```powershell
@"
exit_code=$exit
stderr_log=$stderrLog
session_id=$sid
done_at=$(Get-Date -Format "o")
"@ | Out-File -LiteralPath "$transcriptPath" -Encoding UTF8
```

The `"@` at line 583 (start-of-line) was interpreted by PowerShell as the **terminator of the outer here-string**, prematurely ending `$tuiTemplate`. The `"@` on line 584 became an orphan unmatched terminator.

**Parser result before fix**: 13 errors spanning lines 417–752, cascading from the broken template structure.

---

## 2. Fix Applied

### 2.1 Replaced nested here-string with array-based transcript writing

**Before** (broken):
```powershell
@"
exit_code=$exit
stderr_log=$stderrLog
session_id=$sid
done_at=$(Get-Date -Format "o")
"@ | Out-File -LiteralPath "$transcriptPath" -Encoding UTF8
"@
```

**After** (fixed):
```powershell
# Write transcript using array (avoid nested here-string in template)
`$transcriptLines = [System.Collections.Generic.List[string]]::new()
`$transcriptLines.Add("exit_code=`$exit")
`$transcriptLines.Add("stderr_log=`$stderrLog")
`$transcriptLines.Add("session_id=`$sid")
`$transcriptLines.Add("done_at=`$(Get-Date -Format 'o')")
`$transcriptLines | Out-File -LiteralPath "$transcriptPath" -Encoding UTF8
```

**Key design decisions**:
- Backtick-escaped `$` variables (`$exit`, `$stderrLog`, `$sid`, `$(Get-Date ...)`) expanded at runner **runtime**
- Bare `$transcriptPath` expanded at **template generation time**
- No `@"... "@` inside outer template avoids any here-string nesting

### 2.2 Added missing TUI template terminator

The replacement accidentally dropped the `"@` terminator. Added back on line 585 between transcript block and `Set-Content`.

### 2.3 Deleted leaked `stderr` file

Removed `stderr` file at repository root.

---

## 3. Verification Results

### 3.1 Parser error count

| File | Before | After |
|------|--------|-------|
| scripts/Send-ClaudeCommand.ps1 | 13 errors | 0 errors |
| Generated TUI runner | (impossible) | 0 errors |

### 3.2 Call operator + splatting

Generated runner: `& claude @fullArgs 2>> $stderrLog`
- [x] Call operator with splatting preserved
- [x] No degradation to Start-Process -ArgumentList

### 3.3 Parameter fidelity (receiver test)
- [x] Spaces in paths preserved
- [x] Multi-line text preserved
- [x] Double/single quotes preserved
- [x] Unicode (Chinese, emoji, Greek) preserved

### 3.4 Stderr capture
- [x] 2>> redirects to stderrLog (inside logsDir)
- [x] No stderr leak at repo root

### 3.5 Required fields

Transcript: exit_code, stderr_log, session_id, done_at  
done.json: exit_code, session_id, stderr_log  
sidFile defined in runner for session UUID persistence

### 3.6 Git diff scope
- Modified: scripts/Send-ClaudeCommand.ps1 (allowed)
- Deleted: stderr at repo root (allowed)
- New: this report (allowed)

---

## 4. Summary

| Change | Lines |
|--------|-------|
| Replace nested here-string with array transcript | 578-584 |
| Add TUI template terminator | +1 line |
| Delete stderr leak | -1 file |

**Parser errors**: 13 -> 0  
**All verification checks**: PASS
