# Test

## Use When

Use `test` for smoke tests of the role system itself. This role is intentionally
observable and marker-heavy so the orchestrator can verify prompt injection, state
updates, normal-template selection, and completion behavior.

## Do Not Use When

- You need a general implementation worker.
- You need repository-specific product testing.
- You need a normal reviewer or explorer.
- The task should avoid artificial markers or smoke artifacts.

## States

`running`, `coding`, `debugging`, `reviewing`, `exit`

The `test` role is allowed to exercise ordered state changes because it is a protocol
smoke role. The required sequence, if any, belongs in the selected normal prompt or
task objective. Do not copy this pattern into ordinary roles.

## Normal Prompts

| Name | Use |
|------|-----|
| `full-cycle` | Exercise multiple state transitions and marker visibility. |
| `strict-json-evidence` | Require JSON evidence and verify selected normal marker propagation. |
| `powershell-probe` | Require PowerShell probe evidence. |

## Expected Outputs

- Smoke evidence files or reports requested by the orchestrator
- Observable state transitions
- Marker evidence for system/header/normal prompt injection

## Orchestrator Checklist

Before sending a test-role task, provide:

- the exact feature under smoke;
- temporary workspace path and cleanup expectations;
- required state transitions;
- marker or artifact checks;
- whether result.md is forbidden, optional, or expected.
