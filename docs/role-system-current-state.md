# Role System v2 — Current State

> **Date**: 2026-06-15  
> **Status**: OPERATIONAL — All core features PASS. Known residual risks documented.

## Architecture (Four Layers)

| Layer | Source | Inject Target | Status |
|-------|--------|---------------|--------|
| 1 | `default/system.md` | `--system-prompt-file` | ✅ Stable |
| 2 | `role/<name>/system_prompt/*.md` | `--system-prompt-file` (appended) | ✅ Stable |
| 3 | `role/<name>/legal_state.json` | `--system-prompt-file` (appended) | ✅ Stable |
| 4 | `default/header.md` + `role/<name>/header_prompt/*.md` | Task preamble | ✅ Stable |
| InjectNormal | `role/<name>/normal_prompt/<name>.md` | Task body (explicit `-InjectNormal` only) | ✅ Fully wired |

`normal_prompt` is a **reusable prompt fragment**, not a work mode. Selected explicitly via `send -InjectNormal <name>`. Final position: between completion contract and `TASK:` marker.

## Completion Authority

| Artifact | Role | Status |
|----------|------|--------|
| `.state` JSON (`state=exit, confirmed=true`) | **Sole authority** for task completion | ✅ |
| `Update-WorkerState.ps1` | Only worker-facing lifecycle interface | ✅ |
| Exit confirmation gate | `--exit` (checklist) → `--exit -Confirm` (write) | ✅ |
| `.exit` file | **Deprecated** — not part of v2 protocol | — |
| `result.md` | Optional convenience artifact | ✅ |
| `done.json` | Runner-internal (session UUID capture) | ✅ |

## Key Features — Status Matrix

| Feature | Status | Verified By |
|---------|--------|-------------|
| Role registration (v2 structure) | ✅ PASS | Multiple reports |
| legal_state.json validation | ✅ PASS | Smoke plan Phase 0 |
| InjectNormal end-to-end (CLI → worker prompt) | ✅ PASS | Targeted smoke 2026-06-15 (`V2_TEST_NORMAL_JSON_D4B7`) |
| Queue transaction (Core semantics) | ✅ PASS | Queue final review (14/14 fixture tests) |
| pending_task_error display | ✅ PASS | Boundary repair review (19/19 fixture tests) |
| Sync-DeadToFailed 3s hard timeout | ✅ PASS | Timeout test suite (3/3 tests) |
| TUI observability (parser fix, stderr, transcript) | ✅ PASS | Lifecycle review (0 parser errors) |
| Session UUID capture/resume | ✅ PASS | Targeted smoke + prior testing |
| `-p` mode clean exit + resume | ✅ PASS | Targeted smoke + lifecycle review |
| Missing template rejection (no zombie) | ✅ PASS | Targeted smoke 2026-06-15 |
| Auto-continue failure preserves pending_task | ✅ PASS | Queue final review (static verification) |
| Agent soft-delete preserves store/ | ✅ PASS | Operational |

## Parser Health

| Script | AST Errors |
|--------|-----------|
| `scripts/ClaudeTui.ps1` | 0 |
| `scripts/Send-ClaudeCommand.ps1` | 0 |

## Test Suites

| Suite | Tests | Result |
|-------|-------|--------|
| `Mock-SendFixture.ps1` | 19 | ALL PASS |
| `Sync-DeadToFailed-Timeout-Tests.ps1` | 3 | ALL PASS |
| Targeted smoke (2026-06-15) | 5 areas | ALL PASS |

## Known Residual Risks

| # | Risk | Severity | Mitigation |
|---|------|----------|------------|
| 1 | Crash window: `_DoLaunch` save ↔ `pending_task` clear could cause duplicate execution | Low | Extremely narrow window (same process, two consecutive `Save-Agents` calls) |
| 2 | Orphan process window: launch JSON unparseable after process start | Low | Minimal window; process exists without agents.json entry |
| 3 | No runtime behavioral tests for auto-continue catch path | Low | Static regex verification adequate for repair scope; mock-launch fixtures would improve coverage |
| 4 | `wait` (even with explicit agent ID) runs global `Sync-All` and can process exits of **other** orchestrators' agents | Medium (UX) | Documented in SKILL.md rule 12; avoid `wait all`/`remove all` in shared managers |
| 5 | TUI force-killed sessions not guaranteed resumable | Medium (UX) | Documented; prefer `-p` mode for multi-turn workflows |
| 6 | `Get-Process` in `Send-ClaudeCommand.ps1` still bare (not timeout-wrapped) | Low | Those queries target current/just-launched PIDs, not dead-PID table |
| 7 | `pending_task_error` normalized but only displayed in `agent detail` (not in `agents` list) | Low | Diagnostic field; list view already shows status array |

## Reference Documents

| Document | Purpose |
|----------|---------|
| [role-system-design.md](role-system-design.md) | Authoritative design doc |
| [roles.md](roles.md) | Role CLI reference |
| [agents-json-schema.md](agents-json-schema.md) | Schema, lifecycle, Sync functions |
| [session-uuid-lifecycle.md](session-uuid-lifecycle.md) | UUID capture & resume semantics |
| [test-role-smoke-plan.md](test-role-smoke-plan.md) | Smoke test plan + execution record |

## Verification Reports

| Date | Report | Verdict |
|------|--------|---------|
| 2026-06-15 | [role-system-v2-targeted-smoke-report.md](worker-reports/role-system-v2-targeted-smoke-report.md) | ALL PASS |
| 2026-06-15 | [role-system-v2-injectnormal-boundary-review-report.md](worker-reports/role-system-v2-injectnormal-boundary-review-report.md) | PASS |
| 2026-06-15 | [role-system-v2-queue-final-review-report.md](worker-reports/role-system-v2-queue-final-review-report.md) | CONDITIONAL PASS |
| 2026-06-15 | [role-system-v2-lifecycle-review-report.md](worker-reports/role-system-v2-lifecycle-review-report.md) | PASS WITH RISKS |
| 2026-06-15 | [role-system-v2-sync-dead-timeout-repair-report.md](worker-reports/role-system-v2-sync-dead-timeout-repair-report.md) | Fix applied, verified |
| 2026-06-15 | [role-system-v2-doc-sync-report.md](worker-reports/role-system-v2-doc-sync-report.md) | This sync |
