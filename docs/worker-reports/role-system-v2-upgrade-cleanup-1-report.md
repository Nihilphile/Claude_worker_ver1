# Role System v2 Upgrade — Cleanup 1 Report

> **Author**: role-system-v2-coder-tui (cleanup session)
> **Date**: 2026-06-15
> **Scope**: Narrow cleanup closing 4 LOW findings (N-1 through N-4) from repair 1 re-review.

---

## Based On

| Source | Purpose |
|--------|---------|
| `docs/worker-reports/role-system-v2-upgrade-repair-1-review-report.md` | Re-review findings: N-1 through N-4 |
| `docs/role-system-design.md` | Master design (authoritative) |

---

## Changes Made

### N-1: Remove dead `$RoleStates` parameter — CLOSED

**File**: `scripts/Send-ClaudeCommand.ps1` line 15

**Before**: `[string]$RoleStates = "",` declared in param block but never read (fallback code fully removed in repair 1).

**After**: Parameter removed. No remaining `RoleStates` references anywhere in scripts (verified with `grep -rn`).

### N-2: Fix stale Sync-All comment — CLOSED

**File**: `scripts/ClaudeTui.ps1` line 521

**Before**: `# 1. TUI mode: handle .exit signals with 5s grace period`

**After**: `# 1. Process agents in finishing status with 5s grace period before kill`

Comment now accurately describes the current behavior: Sync-KillPending only processes agents that Sync-ReadState already marked `["finishing"]`. No `.exit` file detection.

### N-3: Document role local-only storage — CLOSED

**File**: `docs/roles.md` — added new section "Role Storage and Git"

Roles under `prompt_templates/role/` are gitignored by default. They are local configuration. For sharing roles, users should use an explicit documentation or repository strategy. The existing `.gitignore` policy (`prompt_templates/role/*` ignored, only `.gitkeep` tracked) is maintained — it aligns with the design that roles are local.

### N-4: Fix SKILL.md `result` description — CLOSED

**File**: `SKILL.md` — CLI command table

**Before**: `| result <id> | Print result.md. |`

**After**: `| result <id> | Convenience viewer: shows state summary + optional result.md. Completion authority is .state JSON. |`

Description now correctly reflects that result is a convenience viewer and `.state` JSON is the completion authority.

---

## Verification

| Method | Result |
|--------|--------|
| PowerShell `Get-Command` × 3 scripts | Update-WorkerState.ps1, Send-ClaudeCommand.ps1, ClaudeTui.ps1: all OK |
| `git diff --check` | Clean (LF→CRLF only) |
| `grep RoleStates scripts/*.ps1` | Zero hits — dead param fully removed |
| `grep \.exit scripts/*.ps1` (excluding exit_code/exit_seen_at/exit_confirmation/.state) | Only Complete-ClaudeTask.ps1 L177 deprecation comment (historical, not functional) |

---

## Files Changed

| File | Change |
|------|--------|
| `scripts/Send-ClaudeCommand.ps1` | Removed `$RoleStates` parameter (L15) |
| `scripts/ClaudeTui.ps1` | Fixed stale Sync-All comment (L521) |
| `docs/roles.md` | Added "Role Storage and Git" section |
| `SKILL.md` | Updated `result` command description |

---

## Handoff

All 4 reviewer findings from repair 1 re-review are closed. No remaining dead references to RoleStates or .exit detection/writing. Documentation accurately reflects v2 authority model (`.state` JSON is completion authority; result.md is convenience viewer; roles are local-only).
