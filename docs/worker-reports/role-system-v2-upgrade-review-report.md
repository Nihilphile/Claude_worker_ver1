# Role System v2 Upgrade Review Report

> **Author**: role-system-v2-reviewer-tui (read-only reviewer)
> **Date**: 2026-06-15
> **Scope**: Review of diff and implementation report against orchestrator final design. No modifications made.

---

## Based On

| Source | Purpose |
|--------|---------|
| `docs/role-system-design.md` | Master final design (authoritative) |
| `docs/worker-reports/role-system-v2-upgrade-planning-report.md` | Planning baseline |
| `docs/worker-reports/role-system-v2-upgrade-implementation-report.md` | Coder claims of what was implemented |
| `scripts/Update-WorkerState.ps1` (145 lines) | Worker state interface |
| `scripts/Complete-ClaudeTask.ps1` (185 lines) | Deprecated completion handler |
| `scripts/Send-ClaudeCommand.ps1` (745 lines) | Worker launcher + prompt builder |
| `scripts/ClaudeTui.ps1` (1395 lines) | Manager CLI + Sync functions |
| `prompt_templates/default/system.md` | State system manual |
| `prompt_templates/default/header.md` | Worker preamble |
| `README.md`, `SKILL.md`, `docs/roles.md` | Documentation |
| `docs/agents-json-schema.md`, `docs/store-vs-run.md` | Schema docs |
| `manifest.json` | Project manifest |

---

## Master Design Reference (authoritative)

The orchestrator final 10 items (supersedes any "compat" language in worker reports):

1. ver2 is incompatible refactor; **NO** consideration of old flat role compatibility.
2. Complete-ClaudeTask is **NOT** a worker-facing API; default prompt must NOT require calling it.
3. **NO** `.exit` signal. Manager lifecycle only polls `.state` JSON; `state=exit` with `confirmed=true` enters finishing/cleanup/finished ready.
4. `done.json`/`result.md` are **NOT** completion authority. `result` command is convenience viewer reading `state` JSON `summary_message`/`evidence`; must NOT treat `result.md` as required artifact.
5. `Update-WorkerState` is the **ONLY** worker-facing lifecycle/state interface.
6. `Update-WorkerState` **MUST** require `AgentName`, `CommandId`, `Role`; use `--<legal-state>` for state transitions; illegal state -> **hard error**.
7. `--exit` first call prints confirmation only, does NOT write state; `--exit -Confirm` writes state JSON.
8. Role mismatch -> **hard error**.
9. `normal_prompt` is NOT auto-injected; only via `-InjectNormal <name>` explicitly.
10. `role register` creates `system_prompt/`/`header_prompt/`/`normal_prompt/` + `legal_state.json`; default legal states `running`/`exit` with Chinese `exit_confirmation`.

---

## Findings

### HIGH Severity

#### H-1: Flat role backward compatibility path violates master requirement #1

| Field | Detail |
|-------|--------|
| **File** | `scripts/ClaudeTui.ps1` lines 612-621 |
| **File** | `scripts/Send-ClaudeCommand.ps1` lines 271-277 |
| **File** | `scripts/ClaudeTui.ps1` lines 416-427 (Sync-ReadState skips validation when `legal_state.json` absent) |
| **Evidence** | ClaudeTui.ps1 L612: `} else { # v1 flat role -- warn but allow (compat)` followed by deprecation warning and RoleStates passthrough. Send-ClaudeCommand.ps1 L271: `} elseif ("$RoleStates" -ne "") { # Fallback: old roles.json states` -- constructs state tracking paragraph from legacy data. Sync-ReadState L416-427: only validates against `legal_state.json` when file exists; flat roles (no `legal_state.json`) proceed silently. |
| **Master design** | Item 1: "ver2 is incompatible refactor, NO consideration of old flat role compatibility" |
| **Implementation report claim** | "Flat roles without `legal_state.json` still work (compat warning, states from roles.json)" |
| **Impact** | The compat path creates technical debt and violates the explicit "incompatible refactor" mandate. Flat roles without `legal_state.json` can still be used with `send`, bypassing the v2 state validation pipeline. Workers assigned flat roles have no legal state enforcement at any layer. |
| **Recommendation** | Remove all compat branches (`elseif ("$RoleStates" -ne "")`, the `else` block in `_DoLaunch` L612). `send` with a role lacking `legal_state.json` should hard error. |

---

#### H-2: `.exit` signal still written by `Update-WorkerState --exit -Confirm`

| Field | Detail |
|-------|--------|
| **File** | `scripts/Update-WorkerState.ps1` lines 140-144 |
| **Evidence** | L140-144: `if ($stateArg -eq "exit" -and $Confirm) { $exitPath = ...; Write-Output "$now" | Out-File ...; Write-Host "... exit signal written (.exit)" }` |
| **Master design** | Item 3: "NO .exit signal. Manager lifecycle only polls .state JSON" |
| **Implementation report claim** | Deviation #2: ".exit signal retained ... as a backward-compatibility measure" |
| **Impact** | The `.exit` file is written on every confirmed exit, contradicting the master design. While Sync-KillPending `.exit` detection is a secondary path, its presence means the system still depends on the legacy signal mechanism. Workers that wrote `.state` with `exit`+`confirmed` can still have their lifecycle gated on `.exit` existence if Sync-ReadState somehow misses the transition. In v2, there should be exactly ONE authoritative signal: `.state` JSON. |
| **Recommendation** | Remove lines 139-144 from `Update-WorkerState.ps1`. Remove `.exit` file detection from `Sync-KillPending` (ClaudeTui.ps1 L460-475). |

---

#### H-3: `Build-WorkerPrompt` makes `result.md` writing a MANDATORY step

| Field | Detail |
|-------|--------|
| **File** | `scripts/Send-ClaudeCommand.ps1` lines 332-347 |
| **Evidence** | L336-337: `MANDATORY COMPLETION -- after the task, do these steps:` / `1. Write a summary of what you did to: $resultPath` |
| **Master design** | Item 4: "done.json/result.md are NOT completion authority ... must NOT treat result.md as required artifact" |
| **Implementation report claim** | Deviation #3: "Build-WorkerPrompt still references result.md ... retained for backward compatibility" |
| **Impact** | The word "MANDATORY" coupled with the instruction to write `$resultPath` as step 1 directly contradicts the master design. Workers are told result.md is required when the design says it is optional. This creates confusion about what authority governs task completion. The system prompt (`default/system.md`) correctly omits result.md requirements, but the worker prompt contradicts it. |
| **Recommendation** | Change "MANDATORY COMPLETION" to "COMPLETION". Change step 1 from "Write a summary of what you did to: $resultPath" to "Optionally write a summary to: $resultPath (the orchestrator reads your state for completion status)". |

---

#### H-4: `Send-ClaudeCommand` blocking wait loop requires `result.md` for completion detection

| Field | Detail |
|-------|--------|
| **File** | `scripts/Send-ClaudeCommand.ps1` line 679 |
| **Evidence** | L679: `if ((Test-Path -LiteralPath $donePath -PathType Leaf) -and (Test-Path -LiteralPath $resultPath -PathType Leaf))` |
| **Master design** | Item 4: "done.json/result.md are NOT completion authority" |
| **Impact** | The `-p` mode wait loop treats `result.md` as equally required as `done.json` for task completion. If a worker skips result.md (as permitted by v2 design), the wait loop will never recognize completion and will time out. This makes result.md a de facto authority despite the design downgrading it. |
| **Recommendation** | Remove the `resultPath` requirement from the wait condition. Detect completion from `donePath` existence alone. The `result.md` path in `done.json` should be treated as optional. |

---

### MEDIUM Severity

#### M-1: Sync-ReadState illegal-state detection is display-only, not a hard error

| Field | Detail |
|-------|--------|
| **File** | `scripts/ClaudeTui.ps1` lines 423-424 |
| **Evidence** | L423-424: `if ($parsedState -notin $legalStates) { Write-Host ("[STATE] HARD ERROR: ...") }` -- prints to console but does NOT reject, block, or roll back the state change. The agent `current_state` is already set to the illegal value (L412). |
| **Master design** | Item 6: "illegal state hard error" (implies rejection, not just logging). Design doc L123: "Validates state against legal_state.json (HARD ERROR display if illegal)" |
| **Impact** | The label "HARD ERROR" is misleading. It is a warning at the manager display level, not an error that prevents the illegal state from being recorded. The illegal state persists in `agents.json.current_state` and the `.state` file. |
| **Recommendation** | Either: (a) reject the state change by not updating `current_state` when illegal, or (b) revert to previous state, or (c) add an `illegal_state_detected` flag to the entry and block further transitions. |

---

#### M-2: Sync-DoneToManager skips `done.json` processing when `.exit` file exists

| Field | Detail |
|-------|--------|
| **File** | `scripts/ClaudeTui.ps1` lines 341-342 |
| **Evidence** | L341-342: `$exitPath = Join-Path ...; if (Test-Path ...exitPath) { continue }` -- skips the agent entirely when `.exit` exists. |
| **Master design** | Item 3: lifecycle driven by `.state` JSON, not `.exit`. |
| **Impact** | In v2, `Update-WorkerState --exit -Confirm` writes BOTH `.state` JSON and `.exit` file (see H-2). When `.exit` exists, `Sync-DoneToManager` skips the agent, preventing it from transitioning from `finishing` to `finished,ready` via `done.json`. This means an agent that properly exits via Update-WorkerState gets stuck if Sync-KillPending has not cleaned it up yet, and Sync-DoneToManager will not process the `done.json` to capture its session UUID. Net effect: session UUID may not be captured for the next resume. |
| **Recommendation** | Remove the `.exit` skip condition (L341-342). Let `done.json` processing proceed regardless of `.exit` existence. Combined with H-2 fix (remove `.exit` writing), this path becomes irrelevant. |

---

#### M-3: `Invoke-RoleUpdate` still supports `-Files` copying (deprecated in v2)

| Field | Detail |
|-------|--------|
| **File** | `scripts/ClaudeTui.ps1` lines 1201-1209 |
| **Evidence** | L1201-1209: `if ($Files -and $Files.Count -gt 0) { Write-Host "... -Files provided; copying to role directory root (deprecated in v2)." ... foreach ($f in $Files) { Copy-Item ... } }` |
| **Impact** | Having `-Files` still functional contradicts the v2 "no file copying" paradigm (`role register` correctly omits `-Files`). A v2 user who accidentally uses old syntax gets a deprecation warning but the old behavior still executes, potentially creating confusion about correct v2 workflow. |
| **Recommendation** | Hard error on `-Files` with message directing users to manually place `.md` files into `system_prompt/`/`header_prompt/`/`normal_prompt/`. |

---

#### M-4: Implementation report overstates backward compatibility as feature

| Field | Detail |
|-------|--------|
| **File** | `docs/worker-reports/role-system-v2-upgrade-implementation-report.md` lines 107-112 |
| **Evidence** | Report section "Backward Compatibility (preserved)" lists 4 items: flat roles work, old text .state parse, .exit still written, Complete-ClaudeTask kept as convenience. Under "Intentional Deviations" #2 and #3, the coder characterizes these as intentional compat measures. |
| **Master design** | Items 1, 3, 4 collectively require NO backward compatibility for the old mechanisms. |
| **Impact** | The implementation report narrative contradicts the master design. Any downstream reader of the report would believe backward compatibility is an accepted design decision, not a deviation. This is misleading. |
| **Recommendation** | The implementation report should be amended to clearly note these as DEVIATIONS from the master design, with rationale for temporary retention and a plan for removal. |

---

### LOW Severity

#### L-1: `scripts/ClaudeTui.ps1.tmp` -- leftover temporary file from coder

| Field | Detail |
|-------|--------|
| **File** | `scripts/ClaudeTui.ps1.tmp` (10600 bytes, created Jun 15 03:50) |
| **Evidence** | Present in `git status --short` as untracked (`??`). |
| **Impact** | Runtime artifact left by coder. Should not be committed. Adds noise to `git status`. |
| **Recommendation** | Delete `scripts/ClaudeTui.ps1.tmp`. |

#### L-2: `store/registry.json` -- untracked runtime artifact

| Field | Detail |
|-------|--------|
| **File** | `store/registry.json` (2431 bytes, created Jun 15 04:04) |
| **Evidence** | Present in `git status --short` as untracked (`??`). Written by `Send-ClaudeCommand.ps1` `Update-AgentRegistry` function. |
| **Impact** | Runtime data that should be in `.gitignore`. Currently shows as untracked. |
| **Recommendation** | Add `store/registry.json` to `.gitignore` or remove it. |

#### L-3: `roles.json` has missing entries for flat role directories

| Field | Detail |
|-------|--------|
| **File** | `prompt_templates/roles.json` -- only contains `test-v2` entry |
| **Evidence** | Directories `prompt_templates/role/tdd-coder/` and `prompt_templates/role/test-r/` exist but have NO corresponding entries in `roles.json`. Only `test-v2` is registered. |
| **Impact** | Stale role directories that exist on disk but are not registered. `role list` will not show them. If someone runs `role register tdd-coder`, they will get a directory conflict. |
| **Recommendation** | Either register these roles or remove their directories. |

#### L-4: Prompt duplication -- `header.md` and `Build-WorkerPrompt` both instruct Update-WorkerState usage

| Field | Detail |
|-------|--------|
| **File** | `prompt_templates/default/header.md` line 4 |
| **File** | `scripts/Send-ClaudeCommand.ps1` lines 336-342 |
| **Evidence** | header.md L4: "When finished, signal completion by calling Update-WorkerState.ps1..." -- Build-WorkerPrompt L338-341: "Signal completion by calling: powershell.exe ... --exit ... Then confirm with: ... --exit -Confirm". The header and the prompt body both describe completion signaling. |
| **Impact** | Workers see duplicate instructions for the exit flow. The header says "signal completion" generally; the body gives specific two-step commands. This is minor but could cause confusion. |
| **Recommendation** | Keep the precise instructions in `Build-WorkerPrompt` only. Make `header.md` just the identity preamble ("You are a ~~ROLE~~ agent. Execute the task, then complete.") without procedure-level guidance. |

#### L-5: `Sync-KillPending` still contains `.exit` detection as legacy path

| Field | Detail |
|-------|--------|
| **File** | `scripts/ClaudeTui.ps1` lines 460-475 |
| **Evidence** | L469-475: `if ("running" -in $entry.status -and $exitFileExists -and "finishing" -notin $entry.status) { $entry.status = @("finishing"); ... }` |
| **Impact** | If H-2 is fixed (removing `.exit` writing), this code becomes dead. Even with current state, it is a secondary path that conflicts with the primary `.state` JSON path. |
| **Recommendation** | Remove after H-2 fix. If H-2 is not fixed, this is still a design smell because there should be ONE way to detect exit. |

#### L-6: README license badge shows "MIT" but actual LICENSE is GPL

| Field | Detail |
|-------|--------|
| **File** | `README.md` line 5 |
| **Evidence** | `[![MIT License](https://img.shields.io/badge/license-GPL-blue.svg)](LICENSE)` -- badge alt text says "MIT License" but links to GPL. |
| **Impact** | Cosmetic. The actual LICENSE file is GPLv3 (per commit 7665419), but the README badge alt text misstates the license name. The badge SVG URL correctly shows "GPL". |
| **Recommendation** | Change badge alt text from `MIT License` to `GPLv3 License`. |

---

## Confirmed OK

The following items were verified and found consistent with the master design:

| # | Item | Verification |
|---|------|-------------|
| 1 | `role register` creates v2 structure (3 subdirs + `legal_state.json`) without requiring `-Files` | ClaudeTui.ps1 Invoke-RoleRegister L1119-1153 |
| 2 | Default `legal_state.json` contains `["running","exit"]` + Chinese `exit_confirmation` | L1131-1136 |
| 3 | `Update-WorkerState` requires AgentName, CommandId, Role (all `Mandatory=$true`) | Update-WorkerState.ps1 L2-12 |
| 4 | Illegal state -> hard error with legal states listing | L92-95 |
| 5 | Role mismatch -> hard error (reads from status.json, then agents.json) | L42-68 |
| 6 | Exit confirmation gate: first `--exit` prints checklist, no state write | L98-116 |
| 7 | Second `--exit -Confirm` writes JSON state with confirmed=true | L118-135 |
| 8 | `-SummaryMessage` stored in state JSON | L129-131 |
| 9 | `normal_prompt/` not auto-injected; only via `-InjectNormal <name>` | Send-ClaudeCommand.ps1 L311-328 |
| 10 | Missing template for `-InjectNormal` -> hard error | L323-327 |
| 11 | `default/system.md` rewritten as State system manual (no old worker contract) | system.md |
| 12 | `Complete-ClaudeTask.ps1` `.exit` writing removed, marked DEPRECATED | Complete-ClaudeTask.ps1 L177-183 |
| 13 | System prompt injection order: Layer 1 (default/system.md) -> Layer 2 (role system_prompt/) -> Layer 3 (legal states + Update-WorkerState usage) | Build-SystemPrompt L226-280 |
| 14 | Role header_prompt/ injected into task preamble (Layer 5) | Build-WorkerPrompt L293-307 |
| 15 | `result` command shows state summary first, graceful on missing result.md | Invoke-Result L1018-1049 |
| 16 | `role show` displays legal_state.json content and directory listings | Invoke-RoleShow L1244-1349 |
| 17 | `role list` shows structure type and legal states per role | Invoke-RoleList L1218-1242 |
| 18 | Send preflight validates running/exit in legal_state.json | _DoLaunch L590-621 |
| 19 | `manifest.json` is valid JSON (Node.js validation passed) | Verified |
| 20 | All 4 core scripts pass `Get-Command` syntax check | Verified |
| 21 | `git diff --check` shows no whitespace errors (only LF->CRLF normalization) | Verified |
| 22 | Coder test role `test-v2-impl` cleaned up (directory not found) | Directory scan |
| 23 | Coder test store/run artifacts cleaned up | Directory scan |

---

## Verification Performed

| Method | Result |
|--------|--------|
| `git status --short` | 11 modified + 5 untracked files (see L-1, L-2) |
| `git diff --check` | No whitespace errors. LF->CRLF normalization only. |
| `git diff --stat HEAD` | 11 files, +634/-161 lines |
| PowerShell `Get-Command` on all 4 core scripts | All 4 pass (coder Test 13 confirmed) |
| PowerShell `[Parser]::ParseFile` static analysis | `Send-ClaudeCommand.ps1` shows parser cascade errors from nested here-string templates (false positive -- `Get-Command` passes, coder tests confirm runtime correctness). Other 3 scripts parse clean. |
| `manifest.json` JSON validation | Valid JSON (Node.js `JSON.parse` confirmed) |
| Manual code audit of all 4 scripts (all functions) | Documented above |
| Cross-reference of implementation report claims vs actual code | 4 HIGH deviations found |
| Directory scan for test artifacts | `test-v2-impl` cleaned up; `.tmp` file remains |
| Role directory structure verification | 3 flat roles still exist, no legal_state.json |

---

## Verification Gaps

1. **Live Claude worker end-to-end**: Could not verify `Update-WorkerState` inside an actual Claude worker session (no Claude API access in this review session). The coder tests were done via direct PowerShell invocation. The `--<state>` positional parameter should work identically via `powershell.exe -File`, but this was not confirmed end-to-end.

2. **Sync-ReadState race with Sync-KillPending**: Could not trigger concurrent state writes and manager polling in this environment. The code logic appears sound but the 5-second grace period interaction with `exit_seen_at` timestamp would benefit from a timed integration test.

3. **Session UUID capture flow**: The `Capture-FreshSessionUuid` function (ClaudeTui.ps1 L242-252) reads from Claude filesystem project directory. This depends on Claude internal file naming and was not tested (no Claude sessions running).

4. **Worker permissions file**: `.claude/worker-permissions.json` is auto-generated by `Send-ClaudeCommand.ps1` but was not tested with actual Claude Code to confirm the permissions are sufficient.

5. **Concurrent multi-agent Sync**: The `Sync-All` function sequences four Sync functions. Theoretical ordering dependency exists (Sync-ReadState must run before Sync-KillPending to set `finishing` status). This was not stress-tested.

---

## Recommendation

**REJECT -- repair required.**

The implementation has four HIGH-severity deviations from the master design that must be addressed before acceptance:

1. **Remove flat role backward compatibility** (H-1): Delete the compat branches in `_DoLaunch` (ClaudeTui.ps1 L612-621), `Build-SystemPrompt` (Send-ClaudeCommand.ps1 L271-277), and `Sync-ReadState` skip path. `send` with a role lacking `legal_state.json` must hard error.

2. **Remove `.exit` signal writing** (H-2): Delete lines 139-144 from `Update-WorkerState.ps1`. Delete `.exit` detection from `Sync-KillPending` (ClaudeTui.ps1 L460-475). The only authoritative exit signal is `.state` JSON.

3. **Demote result.md from MANDATORY to optional** (H-3): Rewrite `Build-WorkerPrompt` L336-342 to not require `result.md` writing. Workers should be told result.md is optional. The state JSON `summary_message` is the authoritative completion summary.

4. **Remove result.md requirement from wait loop** (H-4): Change `Send-ClaudeCommand.ps1` L679 to detect completion from `donePath` alone.

The MEDIUM items (M-1 through M-4) should be addressed before shipping to production, but they do not block acceptance if the HIGH items are fixed first.

The LOW items are cleanup that can be addressed as part of normal maintenance.

---

## Current State Delta

### If Accepted (after repairs)

The v2 role system would provide:
- Layered prompt injection (3-layer system prompt, 3-layer task prompt)
- JSON state tracking with exit confirmation gate
- Role-based legal state enforcement
- Explicit normal_prompt selection via CLI
- `result` command as convenience viewer

### Must Not Claim

The implementation MUST NOT claim:
- "Backward compatibility preserved" -- this was intentionally removed per master design
- "`.exit` signal retained" -- this is a deviation that must be removed
- "result.md is mandatory" -- contradicts master design

### Stale Documentation Found

| File | Issue |
|------|-------|
| `docs/worker-reports/role-system-v2-upgrade-implementation-report.md` (Backward Compatibility section) | Claims flat roles, .exit, old .state format are preserved compat features -- this contradicts master design items 1 and 3 |
| `docs/worker-reports/role-system-v2-upgrade-implementation-report.md` (Intentional Deviations #2, #3) | Characterizes .exit writing and result.md references as "intentional backward compatibility" rather than deviations to be removed |
| `scripts/ClaudeTui.ps1.tmp` | Stale temp file from coder session |
| `prompt_templates/role/tdd-coder/`, `prompt_templates/role/test-r/` | Flat role directories without v2 structure or roles.json entries |
| `store/registry.json` | Untracked runtime artifact |

---

## Summary Statistics

| Metric | Value |
|--------|-------|
| Files reviewed | 15+ |
| HIGH findings | 4 (all blocking) |
| MEDIUM findings | 4 (should fix before production) |
| LOW findings | 6 (cleanup/nice-to-have) |
| Confirmed OK items | 23 |
| Verifications performed | 8 methods |
| Verification gaps | 5 |
| Lines of code audited | ~3,500 |
| Recommendation | REJECT -- repair required |
