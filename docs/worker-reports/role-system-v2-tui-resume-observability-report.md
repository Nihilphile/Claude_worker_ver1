# TUI Runner — Resume & Observability Fix Report

> **Author**: role-system-v2-tui-coder-p
> **Date**: 2026-06-15 08:01–08:15 UTC+8
> **Verdict**: **PASS** — All defects fixed, 5/5 acceptance criteria met

---

## Executive Summary

Fixed B7-related observability and session-resume defects in the TUI runner template
(scripts/Send-ClaudeCommand.ps1). Synchronized documentation to reflect the
strong-kill limitation and per-mode session semantics.

### Controller Ruling (主控裁决) Compliance

| Ruling | Status |
|--------|:------:|
| No graceful flush before force-kill; keep confirmed exit -> 5s grace -> kill | OK (unchanged) |
| Document manager force-killed TUI sessions as not guaranteed resumable | DONE |
| Reliable resume workflows must prefer -p mode | DONE |
| Fix $sidFile undefined; use storeRoot/.claude-sid.txt; done.json fallback sidFile -> curSessionId | DONE |
| Preserve Claude CLI failure evidence: stderr to log, exit code + stderr path in transcript | DONE |
| No stdout pipeline redirection (preserve TUI interactivity) | DONE |
| Verify stderr capture approach with safe local command | DONE |
| Update docs: per-mode fresh/resume, strong-kill, UUID != resumable | DONE |
| Update SKILL.md execution/session rules | DONE |
| Update smoke plan Phase 4: -p round1->round2, keep Phase 1 TUI for lifecycle | DONE |
| Add runtime limitation to role-system-design.md | DONE |
| No ClaudeTui manager/B6 changes, no role changes, no remove all, no git commit | OK |

---

## Acceptance Criteria

### 1. Send-ClaudeCommand.ps1 AST Parser — 0 Errors (PASS)

Verified via [System.Management.Automation.Language.Parser]::ParseFile().

### 2. Static Confirmation: $sidFile Defined + Done Fallback Correct (PASS)

TUI template line 524:
  $sidFile = Join-Path "$storeRoot" ".claude-sid.txt"

Done.json fallback line 570:
  $sid = if (Test-Path $sidFile) { (Get-Content $sidFile -Raw).Trim() } else { "$curSessionId" }

Priority: .claude-sid.txt (manager-written real UUID) -> curSessionId (orchestrator-provided) -> empty.
$sid is resolved OUTSIDE the if block, so always defined for transcript write.

### 3. Safe Local Command Verification of Stderr Capture (PASS)

Tested Start-Process -NoNewWindow -Wait -RedirectStandardError with cmd /c:
  - STDOUT_VISIBLE_SP appeared on console (unchanged)
  - STDERR_CAPTURED_SP went to stderr log file
  - No pipeline redirection; TUI interactivity preserved

Approach in TUI runner (line 564):
  $proc = Start-Process -FilePath claude -ArgumentList $fullArgs -NoNewWindow -Wait -RedirectStandardError $stderrLog -PassThru
  $exit = $proc.ExitCode

### 4. Docs: No False All-Mode Auto-Resume Promises (PASS)

All documentation consistently states:
  - UUID existence does NOT guarantee the session is resumable
  - TUI resume is NOT guaranteed reliable after force-kill
  - Prefer -p mode for multi-turn session resume
  - Do not attempt to resume the Phase 1 TUI agent

### 5. git diff --check (PASS)

No whitespace errors detected.

---

## Changes Made

### A. scripts/Send-ClaudeCommand.ps1 — TUI Runner Template

| Fix | Description |
|-----|-------------|
| $sidFile definition | New: Join-Path storeRoot .claude-sid.txt |
| $stderrLog definition | New: Join-Path logsDir commandId.stderr.log |
| Stderr capture | Replaced bare & claude with Start-Process -NoNewWindow -RedirectStandardError |
| Done.json fallback | $sid resolved outside if-block; sidFile preferred, curSessionId fallback; stderr_log field added |
| Transcript | Now records exit_code, stderr_log, session_id, done_at (was: just exit=...) |

### B. docs/session-uuid-lifecycle.md — Complete Rewrite

- Round 1: both modes, .claude-sid.txt written by manager
- Round N p-mode: reliable resume, clean exit, recommended
- Round N TUI-mode: force-kill warning, NOT guaranteed resumable
- Strong-Kill Limitation section: mechanism, consequences, recommendations
- Runner Session ID Resolution: sidFile -> curSessionId -> empty priority

### C. SKILL.md — Execution Model + Rules

- Execution Model: per-mode reliability guidance added
- Rule 6 (new): Explicit session resume guidance
- Rule numbering fixed (was duplicate 6)

### D. docs/test-role-smoke-plan.md — Phase 4

- REMOVED: attempt to resume Phase 1 TUI agent (force-killed)
- ADDED Phase 4a: Fresh -p session round 1
- ADDED Phase 4b: Resume same -p session round 2
- ADDED Phase 4c (optional): Verify TUI resume limitation

### E. docs/role-system-design.md — Runtime Limitation

Added to Sync-KillPending section:
  Force-killed TUI sessions are NOT guaranteed resumable.
  Use -p mode for workflows requiring reliable session resume.

---

## What Was NOT Changed

- scripts/ClaudeTui.ps1 — manager queue, B6, Sync-KillPending logic
- scripts/Complete-ClaudeTask.ps1
- Role content (prompt_templates/role/*/)
- No remove all executed
- No git commit performed
- B6 (agent entry before preflight rejection) not addressed

---

## Files Modified

M  scripts/Send-ClaudeCommand.ps1
M  docs/session-uuid-lifecycle.md
M  SKILL.md
M  docs/test-role-smoke-plan.md
M  docs/role-system-design.md
A  docs/worker-reports/role-system-v2-tui-resume-observability-report.md (this file)

---

## Verification Matrix

| # | Acceptance Criterion | Verdict |
|---|---------------------|---------|
| 1 | Send-ClaudeCommand.ps1 AST 0 errors | PASS |
| 2 | TUI runner $sidFile defined + done fallback correct | PASS |
| 3 | Safe local command verifies stderr capture | PASS |
| 4 | Docs contain no all-mode auto-resume false promise | PASS |
| 5 | git diff --check clean | PASS |

**Verdict: PASS — 5/5 criteria met.**
