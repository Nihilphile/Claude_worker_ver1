# Role System v2 Upgrade — Repair 1 Re-Review Report

> **Author**: role-system-v2-reviewer-tui (read-only re-reviewer)
> **Date**: 2026-06-15
> **Scope**: Re-review of repair 1 against the 4 HIGH + related MEDIUM/LOW findings from the prior review.

---

## Based On

| Source | Purpose |
|--------|---------|
| `docs/role-system-design.md` | Master design (authoritative) |
| `docs/worker-reports/role-system-v2-upgrade-review-report.md` | Prior review with 4 HIGH, 4 MEDIUM, 6 LOW |
| `docs/worker-reports/role-system-v2-upgrade-repair-1-report.md` | Repair 1 claims (14 items closed) |
| `scripts/Update-WorkerState.ps1` (141 lines) | .exit removal, role validation |
| `scripts/ClaudeTui.ps1` (1384 lines) | Flat role compat, Sync-ReadState, Sync-KillPending, Sync-DoneToManager, Invoke-RoleUpdate |
| `scripts/Send-ClaudeCommand.ps1` (745 lines) | RoleStates fallback, Build-WorkerPrompt, wait loop |
| `prompt_templates/default/header.md` | Duplicate instruction cleanup |
| `prompt_templates/roles.json` | Reset to {} |
| `.gitignore` | store/registry.json added |
| `README.md` | License badge fix |

---

## Verdict

**PASS WITH RISKS** — all 4 HIGH blocking findings are fully closed. The residual risks are LOW severity and do not block acceptance.

---

## Per-Finding Closure Audit

### HIGH Severity — All CLOSED

#### H-1: Flat role backward compatibility — CLOSED

| Location | Before Repair | After Repair | Verdict |
|----------|--------------|-------------|---------|
| `ClaudeTui.ps1` `_DoLaunch` L607-612 | `else { # v1 flat role -- warn but allow (compat) ... RoleStates passthrough }` | `else { Write-Host "[MANAGER] Rejected: Role '$Role' has no legal_state.json..." ; exit 1 }` | **CLOSED** — Hard error. |
| `Send-ClaudeCommand.ps1` `Build-SystemPrompt` L249-271 | `elseif ("$RoleStates" -ne "") { # Fallback: old roles.json states ... }` | Fallback block completely removed. Only `legal_state.json` path exists. | **CLOSED** — No RoleStates fallback. |
| `ClaudeTui.ps1` `Sync-ReadState` L409-416 | Validated only when `legal_state.json` exists; flat roles silently skipped | Missing `legal_state.json` → `[STATE] PROTOCOL ERROR` → `continue` (skip agent) | **CLOSED** — Protocol error blocks state advance. |

**Evidence (code)**:
- ClaudeTui.ps1 L607-612: `Write-Host "[MANAGER] Rejected: Role '$Role' has no legal_state.json. Use 'role register $Role' to create a v2 role."` → `exit 1`
- Send-ClaudeCommand.ps1 L249-271: Only `if (Test-Path ...legal_state.json)` path; no `elseif` fallback block
- ClaudeTui.ps1 L412-416: `if (-not (Test-Path ...legal_state.json)) { Write-Host "[STATE] PROTOCOL ERROR..."; continue }`

**Residual**: `$RoleStates` parameter still declared in `Send-ClaudeCommand.ps1` L15 but never populated. Dead code — harmless, LOW cleanup item.

---

#### H-2: `.exit` signal still written — CLOSED

| Location | Before Repair | After Repair | Verdict |
|----------|--------------|-------------|---------|
| `Update-WorkerState.ps1` L139-144 | `if ($stateArg -eq "exit" -and $Confirm) { ... Write-Output ... > .exit }` | `# v2: NO .exit signal. Manager lifecycle is driven solely by .state JSON` (comment only) | **CLOSED** — No .exit write. |
| `ClaudeTui.ps1` `Sync-KillPending` L460-475 | `.exit` file detection → set finishing | Entire block removed. Only processes agents already in ["finishing"] (set by Sync-ReadState). | **CLOSED** — No .exit detection. |
| `ClaudeTui.ps1` `Sync-DoneToManager` L341-342 | Skip agent when `.exit` exists | Removed. No .exit condition. | **CLOSED** — done.json processing not gated on .exit. |

**Evidence (code)**:
- Update-WorkerState.ps1 L139: Comment `# v2: NO .exit signal...` followed by `exit 0` on L141 — no file write
- ClaudeTui.ps1 L462-513: `Sync-KillPending` only handles `if ("finishing" -in $entry.status)` grace period logic; L470 comment: `# v2: No .exit file detection.`
- ClaudeTui.ps1 L327-362: `Sync-DoneToManager` — no exitPath variable, no .exit file check

**Residual**: Sync-All comment L521 still says `# 1. TUI mode: handle .exit signals with 5s grace period`. This is a **stale comment** — Sync-KillPending no longer handles `.exit` files, only processes agents that Sync-ReadState marked `["finishing"]`. LOW, cosmetic.

---

#### H-3: Build-WorkerPrompt mandates result.md — CLOSED

| Location | Before Repair | After Repair | Verdict |
|----------|--------------|-------------|---------|
| `Send-ClaudeCommand.ps1` L329-331 | `MANDATORY COMPLETION — after the task, do these steps:` / `1. Write a summary of what you did to: $resultPath` | `COMPLETION — after the task, do these steps:` / `1. (Optional) Write a summary of what you did to: $resultPath` / `(The orchestrator reads your .state JSON for completion status; result.md is a convenience artifact.)` | **CLOSED** — Not mandatory. |

**Evidence (code)**:
- Send-ClaudeCommand.ps1 L329: `COMPLETION — after the task, do these steps:`
- L330-331: `1. (Optional) Write a summary of what you did to: $resultPath` / `(The orchestrator reads your .state JSON for completion status; result.md is a convenience artifact.)`

**Residual**: None. The word "MANDATORY" is completely removed from the worker prompt. The `$resultPath` variable still exists for optional writing. No grep hits for "MANDATORY COMPLETION" in any script or template.

---

#### H-4: Wait loop requires result.md — CLOSED

| Location | Before Repair | After Repair | Verdict |
|----------|--------------|-------------|---------|
| `Send-ClaudeCommand.ps1` L673 | `if ((Test-Path ...donePath) -and (Test-Path ...resultPath))` | `if (Test-Path ...donePath)` | **CLOSED** — Only donePath required. |

**Evidence (code)**:
- Send-ClaudeCommand.ps1 L673: `if (Test-Path -LiteralPath $donePath -PathType Leaf)` — single condition, no resultPath check.

**Impact**: If a worker writes done.json but not result.md, the wait loop will still detect completion and exit. The `Write-Host "Result: $resultPath"` on L682 is informational only (prints the path, doesn't check existence).

**Residual**: None.

---

### MEDIUM Severity — All CLOSED or Acceptable

| # | Finding | Status | Evidence |
|---|---------|--------|----------|
| M-1 | Sync-ReadState illegal state is display-only | **CLOSED** | ClaudeTui.ps1 L420-429: Illegal state → `Write-Host "[STATE] HARD ERROR..."`, `state_error` field set, `continue` (does NOT update `current_state`). Agent record saved with error marker. |
| M-2 | Sync-DoneToManager skips .exit | **CLOSED** | ClaudeTui.ps1 L327-362: No exitPath variable, no .exit condition. Only "running" status gate remains. |
| M-3 | Invoke-RoleUpdate -Files functional | **CLOSED** | ClaudeTui.ps1 L1192-1198: `if ($Files -and $Files.Count -gt 0) { Write-Host "[MANAGER] ERROR: -Files is not supported in v2." ... exit 1 }` |
| M-4 | Implementation report overstates compat | **NOTED** | Historical artifact; repair report supersedes it. Not modified (out of scope for code repair). |

---

### LOW Severity — All CLOSED or Cleaned

| # | Finding | Status | Evidence |
|---|---------|--------|----------|
| L-1 | ClaudeTui.ps1.tmp leftover | **CLOSED** | File deleted. `ls` confirms absent. |
| L-2 | store/registry.json untracked | **CLOSED** | `.gitignore` L8: `store/registry.json` added. File still exists on disk but is now ignored. |
| L-3 | Stale flat role dirs | **CLOSED** | tdd-coder/, test-r/, test-v2/ directories deleted. `prompt_templates/role/` now contains only `.gitkeep`. `roles.json` reset to `{}`. |
| L-4 | Header.md duplicate instructions | **CLOSED** | `header.md` reduced to 2 lines: `[worker]` / `You are a ~~ROLE~~ agent. Execute the task, then complete.` No completion procedure text. |
| L-5 | Sync-KillPending .exit path | **CLOSED** | Removed as part of H-2 fix. |
| L-6 | README badge alt text | **CLOSED** | `README.md` L5: `[![GPLv3 License](https://img.shields.io/badge/license-GPL-blue.svg)](LICENSE)` |

---

## Analysis of Repair Report Residual Risks

### Residual Risk #1: V1 text-format .state files skipped

**Repair report claim**: "Old text-format .state files from before this repair session will be silently skipped."

**Assessment**: **ACCEPTABLE — by design.** The master design (Item 1: incompatible refactor, Item 3: no v1 back-compat) explicitly requires no backward compatibility. Code evidence: ClaudeTui.ps1 L382-397 — only JSON parse attempted; L393-397: `catch { Write-Host "...skipping"; continue }`. Workers must write new JSON format via Update-WorkerState.ps1.

**Severity**: NONE. This is the intended behavior.

---

### Residual Risk #2: Sync-DoneToManager might preempt Sync-KillPending

**Repair report claim**: "If the worker writes done.json immediately after exit+confirmed, the transition sequence is: Sync-ReadState sets finishing + exit_seen_at → Sync-DoneToManager finds done.json and transitions to finished,ready → Sync-KillPending finds agent not in finishing and skips the kill."

**Assessment**: **CLAIM NOT REPRODUCIBLE — the race described does not exist.** Code analysis:

1. `Sync-All` ordering (ClaudeTui.ps1 L516-529):
   - Sync-ReadState (position 0) — runs FIRST
   - Sync-KillPending (position 1) — runs SECOND
   - Sync-DoneToManager (position 2) — runs THIRD

2. `Sync-DoneToManager` guard (L334): `if ("running" -notin $entry.status) { continue }`. This means Sync-DoneToManager ONLY processes agents with `["running"]` status.

3. When Sync-ReadState detects `exit+confirmed`, it sets `status = ["finishing"]` (L447). "running" is no longer in the status array.

4. Therefore, Sync-DoneToManager will ALWAYS skip the agent during the grace period, regardless of whether done.json exists.

**Conclusion**: The race described in the repair report cannot occur with the current Sync-All ordering and status gating. Sync-DoneToManager CANNOT preempt Sync-KillPending.

**However**, there IS a pre-existing minor concern: if done.json is written during the finishing grace period (after Sync-ReadState sets finishing but before Sync-KillPending kills the process), it will never be processed by Sync-DoneToManager because the agent transitions from finishing → finished,ready without ever returning to "running" status. Impact:
- Session UUID from done.json won't be captured (but UUID is also captured by filesystem scanning)
- Auto-continue for queued tasks won't trigger from done.json (but the agent is already in finished/ready state, so wait/re-send will work)

**Severity**: LOW. This is a pre-existing behavior unrelated to the repair. The `.state` JSON is the authoritative completion signal; done.json processing is a secondary convenience.

---

### Residual Risk #3: Role register always overwrites roles.json

**Repair report claim**: "If Invoke-RoleRegister is called for a role that exists only on disk (no roles.json entry), it will create a new v2 directory structure."

**Assessment**: **Minor edge case — function as designed.** Code evidence: ClaudeTui.ps1 L1099-1108 — only checks `roles.json` for conflicts. A directory on disk without a roles.json entry won't be detected. If there IS a directory (e.g., from a previous manual creation), `-Force` handles it by deleting first. Without `-Force`, `New-Item -Force` on L1118 silently succeeds (it recreates the path but PowerShell `New-Item -Force` doesn't complain about existing directories — it only ensures they exist). No data loss risk.

**Severity**: LOW. Cosmetic edge case.

---

## New Findings (discovered during re-review)

### N-1: `$RoleStates` dead parameter (LOW)

| Field | Detail |
|-------|--------|
| **File** | `scripts/Send-ClaudeCommand.ps1` line 15 |
| **Evidence** | `[string]$RoleStates = ""` is declared in the param block but never read. The fallback code that used it was entirely removed from `Build-SystemPrompt`. The `_DoLaunch` in ClaudeTui.ps1 no longer passes RoleStates to Send-ClaudeCommand. |
| **Impact** | Dead parameter, no runtime effect. Maintainability concern only. |
| **Recommendation** | Remove `$RoleStates` from param block and the `$sendArgs['RoleStates']` assignment if any remains. |

### N-2: Sync-All stale comment (LOW)

| Field | Detail |
|-------|--------|
| **File** | `scripts/ClaudeTui.ps1` line 521 |
| **Evidence** | `# 1. TUI mode: handle .exit signals with 5s grace period` — but Sync-KillPending no longer detects `.exit` files. It only processes agents in `["finishing"]` status. |
| **Impact** | Misleading comment. No runtime effect. |
| **Recommendation** | Change to `# 1. Process agents in finishing status with 5s grace period before kill`. |

### N-3: `prompt_templates/role/*` is gitignored (LOW)

| Field | Detail |
|-------|--------|
| **File** | `.gitignore` line 28-29 |
| **Evidence** | `prompt_templates/role/*` and `!prompt_templates/role/.gitkeep` — all role directories are ignored by git. Only `.gitkeep` is tracked. |
| **Impact** | When a user registers a role, its directory won't be committed. This is intentional (roles are local config), but it means `role register` creates entirely local-only state. The design doc doesn't explicitly address this. |
| **Recommendation** | Document in design doc or README that roles are local-only and not tracked by git. Acceptable if intentional. |

### N-4: `Send-ClaudeCommand.ps1` parser warnings (LOW, pre-existing)

Same false-positive cascade from nested here-string template (`return @" ... "@`) as in the prior review. Not a runtime issue — `Get-Command` passes and prior coder tests confirmed runtime correctness. The parser interprets template text inside the here-string as PowerShell code.

---

## Verification Performed

| Method | Result |
|--------|--------|
| `git status --short` | 11 modified + 3 untracked (worker-reports, role-system-design.md, Update-WorkerState.ps1). No `.tmp` file, no stale role dirs. |
| `git diff --check` | Clean — only pre-existing LF→CRLF normalization. |
| PowerShell `Get-Command` × 4 scripts | All 4 pass. |
| PowerShell `[Parser]::ParseFile` × 4 | 3 clean; Send-ClaudeCommand.ps1: 43 warnings (same false-positive from here-string, confirmed non-runtime). |
| `rg` search for `.exit` (all .ps1) | Zero active `.exit` file writes or detections. Only comments, legacy docs, and `exit_code` property refs. |
| `rg` search for `flat role` / `backward compat` / `v1 compat` (all .ps1) | Zero hits in scripts. |
| `rg` search for `MANDATORY COMPLETION` (all files) | Only in worker-reports (historical). Zero in scripts or templates. |
| `rg` search for `RoleStates` (all .ps1) | Only L15 param declaration (dead). Zero in Build-SystemPrompt or _DoLaunch. |
| Manual code audit | Full function-level audit of all 4 repaired areas. |
| Directory scan | Flat roles deleted, `.tmp` deleted, `roles.json` = `{}`. |
| Design doc compat language | `role-system-design.md` L74-75: "legal_state.json is mandatory for all roles" / "no flat role compat". L132: "No v1 text-format fallback". L138: "Does NOT detect .exit files." L143: "No longer required in worker prompt." |

---

## Verification Gaps (carried forward)

| # | Gap | Relevance to Repair 1 |
|---|-----|----------------------|
| 1 | Live Claude worker end-to-end | Unchanged — cannot test worker-side `Update-WorkerState` integration |
| 2 | Sync-ReadState/Sync-KillPending race | Analyzed via code audit; no live concurrency test |
| 3 | Session UUID capture | Unchanged — requires live Claude |
| 4 | Worker permissions file | Unchanged — requires live Claude |
| 5 | Concurrent multi-agent Sync | Unchanged |

---

## Recommendation

**Accept repair 1 and proceed to next phase.**

The 4 HIGH findings from the prior review are fully closed with clean code. All related MEDIUM and LOW findings are also resolved. The only blockers would be:
- Residual risk #2 (Sync-DoneToManager race) — analyzed and found NOT REAL due to `running` status guard
- The three new LOW findings (N-1, N-2, N-3) are cosmetic cleanup items

### If proceeding, next steps should focus on:
1. **Integration testing** — end-to-end with a real Claude worker to validate `Update-WorkerState` → `Sync-ReadState` → `Sync-KillPending` flow
2. **Documentation sync** — update SKILL.md "result" description to clarify it's a convenience viewer, not an authority
3. **Cleanup N-1, N-2** — remove dead `$RoleStates` param, fix stale Sync-All comment
4. **Decide on N-3** — document that roles are local-only (gitignored)

---

## Summary Statistics

| Metric | Value |
|--------|-------|
| HIGH findings from prior review | 4 — all CLOSED |
| MEDIUM findings from prior review | 4 — all CLOSED or NOTED |
| LOW findings from prior review | 6 — all CLOSED |
| New findings discovered | 4 (N-1 through N-4, all LOW) |
| Scripts verified | 4 (+1 deleted) |
| Verdict | **PASS WITH RISKS** |
| Blocking issues | 0 |
| Residual risks (acceptable) | 4 |
