# Creating Roles (v2)

Roles are project-independent collaboration contracts designed by the orchestrator.
They define durable authority, boundaries, evidence standards, and observable work
states. Project paths, concrete objectives, acceptance criteria, and one-off
instructions belong in the task prompt instead.

## Start With The Contract

Before registering a role, answer these questions:

1. What decision or work product does this role support?
2. What may it read, write, execute, or decide?
3. What must remain owned by the orchestrator or another role?
4. What evidence is required before it may claim success?
5. When must it stop and escalate?
6. Which work states are useful for an external observer?

If these answers depend on one repository or one task, they are probably task-prompt
content rather than role content.

## Choose The Prompt Layer

| Content | Location | Use |
|---------|----------|-----|
| Durable authority, prohibitions, evidence rules, state semantics | `system_prompt/*.md` | Always injected into the compression-resistant system prompt |
| Short identity, stance, and default delivery shape | `header_prompt/*.md` | Always injected into the task preamble |
| Frequently reused workflow variants | `normal_prompt/<name>.md` | Injected only with `-InjectNormal <name>` |
| Repository paths, objective, scope, accepted facts, acceptance criteria | Task `-Prompt` | Supplied by the orchestrator for each command |
| Observable legal work states and exit confirmation | `legal_state.json` | Validated by the manager and state-update command |

Do not duplicate the same long instructions across layers. Put durable rules in the
system layer, a compact reminder in the header, and optional procedures in normal
templates.

## Register The Role

```powershell
$tui = "./scripts/ClaudeTui.ps1"
& $tui role register explorer
```

Registration creates:

```text
prompt_templates/role/explorer/
├── system_prompt/
├── header_prompt/
├── normal_prompt/
└── legal_state.json
```

Place Markdown files directly in the three prompt directories. Files in the system
and header directories are concatenated alphabetically, so use numeric prefixes when
ordering matters.

## Design Legal States

`running` and `exit` are mandatory. Add a state only when it gives the orchestrator
useful information or controls a meaningful protocol boundary.

Good states describe externally observable conditions, such as `investigating`,
`verifying`, or `blocked`. Avoid turning every checklist item into a state.

For every custom state, the system prompt should say:

- when the worker enters it;
- what evidence or condition it represents;
- when it leaves it;
- whether `SummaryMessage` is expected.

The exit confirmation should test the role's ending obligations without assuming a
specific artifact such as `result.md`.

Example:

```json
{
  "version": "1",
  "states": ["running", "investigating", "verifying", "blocked", "exit"],
  "exit_confirmation": "Have you answered the assigned questions, separated facts from inference, and left reviewable evidence?",
  "description": "Evidence-gathering lifecycle"
}
```

## Design Normal Templates

`normal_prompt` is a reusable procedure library, not the task body and not an
automatic part of the role. A template should represent a recurring mode such as a
question pass, architecture trace, runtime probe, implementation pass, or review
checklist.

```powershell
& $tui send explorer-1 `
  -Role explorer `
  -InjectNormal architecture-trace `
  -Prompt "Trace the event flow for the assigned subsystem. Scope: ..."
```

Without `-InjectNormal`, no normal template is injected.

## Validate Before Use

```powershell
& $tui role list
& $tui role show explorer
```

Then verify the role with a bounded smoke:

1. `send` accepts the registered role and rejects an unregistered role.
2. System and header files appear in the generated prompts in alphabetical order.
3. No normal template appears without `-InjectNormal`.
4. Exactly the selected normal template appears with `-InjectNormal`.
5. Legal custom states succeed; an unknown state hard-errors and lists legal states.
6. `--exit` only displays the role confirmation; `--exit -Confirm` writes confirmed
   exit JSON.
7. Role mismatch is rejected.
8. Completion does not depend on `result.md` or an `.exit` file.

## Common Mistakes

- Encoding project paths or current feature details in the role.
- Asking the role to both gather evidence and make the orchestrator's final decision.
- Putting optional procedures in the always-injected system prompt.
- Using `normal_prompt` as an automatic task body.
- Adding states without defining their transition semantics.
- Making `result.md` or another fixed artifact part of the exit contract.
- Treating registration alone as proof that prompt injection and state validation work.

## Storage And Sharing

Role directories and `prompt_templates/roles.json` are local runtime configuration and
are gitignored by default. A registered role is immediately usable on the current
machine but is not automatically distributed with the repository.

If roles should ship as built-in assets, define an explicit tracked role-pack location
or packaging/import mechanism rather than relying on local registration state.

