# Role System v2 — Documentation Sync Report

> **Author**: role-system-v2-doc-curator-p  
> **Date**: 2026-06-15  
> **Mode**: p (pipeline, fresh session)  
> **Scope**: Sync documents to reflect current state from 5 verification reports. No runtime code changes, no tests, no git commit.

## Sources Reviewed

| # | Report | Key Facts Extracted |
|---|--------|---------------------|
| 1 | `role-system-v2-lifecycle-review-report.md` | TUI here-string repair PASS; Sync-DeadToFailed timeout PASS; 0 parser errors both scripts; 17/17 tests PASS |
| 2 | `role-system-v2-queue-final-review-report.md` | Core queue semantics PASS (14/14 fixture tests); pending_task_error recorded but not originally displayed; InjectNormal gap at Send-ClaudeCommand boundary; crash window risk |
| 3 | `role-system-v2-injectnormal-boundary-review-report.md` | Boundary repair: InjectNormal fully wired to Send-ClaudeCommand.ps1; pending_task_error now displayed; 19/19 fixture tests PASS |
| 4 | `role-system-v2-targeted-smoke-report.md` | Real-chain test ALL PASS; marker V2_TEST_NORMAL_JSON_D4B7 confirmed in prompt + JSON artifact; missing template rejection confirmed; temp workspace cleaned |
| 5 | `role-system-v2-sync-dead-timeout-repair-report.md` | 3-second hard timeout via Start-Job/Wait-Job; prevents zombie-PID CLI hangs; 3/3 tests PASS |

## Documents Modified

### 1. `docs/agents-json-schema.md`
- **Added** `pending_task_error` property to schema (nullable string, top-level entry field)
- **Updated** InjectNormal Queue Preservation: noted end-to-end wiring through Send-ClaudeCommand.ps1 + targeted smoke verification
- **Added** Auto-Continue Failure Recovery section documenting pending_task preservation, pending_task_error recording, and crash-window residual risk
- **Updated** Sync Functions table: noted Sync-DeadToFailed uses `Start-Job`/`Wait-Job -Timeout 3` hard timeout

### 2. `docs/role-system-design.md`
- **Updated** `normal_prompt` CLI section: emphasized fragment semantics (not a mode), documented end-to-end injection chain with targeted smoke verification, noted injection position (between contract and TASK: marker)
- **Added** "Current Operational Notes" section with 4 subsections:
  - InjectNormal Fully Wired (boundary repair + smoke verification)
  - Sync-DeadToFailed Hard Timeout (3s ceiling, zombie-PID prevention)
  - pending_task_error Visibility (display in agent detail)
  - TUI Observability (parser fix, here-string repair)

### 3. `docs/roles.md`
- **Updated** "Using a Role": clarified `-InjectNormal` injects a fragment between contract and TASK marker; noted end-to-end wiring with smoke verification

### 4. `docs/session-uuid-lifecycle.md`
- **Added** "Verified Behavior" section: noted `-p` mode clean exit confirmed by targeted smoke; TUI force-kill limitation confirmed

### 5. `docs/test-role-smoke-plan.md`
- **Added** "Prior Execution Record" section: documented 2026-06-15 targeted smoke results (Phases 0–2 subset ALL PASS), with link to smoke report

### 6. `SKILL.md`
- **Updated** Reference table: added `docs/role-system-current-state.md` as first entry
- **Added** Rule 12: documented that `wait` (even with explicit agent ID) runs global `Sync-All` and can process other orchestrators' agent exits

### 7. `README.md`
- **Updated** Files table: noted `Send-ClaudeCommand.ps1` now receives `-InjectNormal`; noted `agents.json` includes `pending_task_error`
- **Added** "Current State" section linking to `docs/role-system-current-state.md`

## New Documents Created

| Document | Purpose |
|----------|---------|
| `docs/role-system-current-state.md` | One-page overview: architecture, completion authority, feature status matrix, parser health, test suites, known residual risks, reference documents, verification report index |
| `docs/worker-reports/role-system-v2-doc-sync-report.md` | This report |

## Verification

- **`rg` grep for key terms**: All key terms (`InjectNormal`, `pending_task_error`, `Sync-DeadToFailed`, `targeted smoke`) appear in appropriate documentation files.
- **Git diff scope**: Only allowed documents modified (docs/*.md, SKILL.md, README.md) plus two new files. No runtime scripts, no tests, no git operations.
- **No long report copies**: Documents contain current state, design decisions, usage patterns, and residual risks only — with links to source reports, not copied report bodies.

## Residual Items (Not in Scope)

- Test artifact cleanup (`tests/generated-runner-*.ps1`, `receiver-args.txt`, `test-capture.stderr.log`) — completed by cleanup report; tests directory now retains only Mock-SendFixture, Sync-DeadToFailed-Timeout-Tests, receiver, stderr-stub
- Cosmetic indentation fix in `Send-ClaudeCommand.ps1` lines 558–559 — low priority, not a document change
- Runtime mock test creation for auto-continue catch path — test code, not document change
