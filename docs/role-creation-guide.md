# Creating Roles (v2)

Roles are project-independent collaboration contracts designed by the orchestrator.
They define durable authority, boundaries, evidence standards, and observable work
states. Project paths, concrete objectives, acceptance criteria, and one-off
instructions belong in the task prompt instead.

Each role should also have a short orchestrator-facing profile under
`docs/role-profiles/<role>/README.md`. The profile is a usage guide, not prompt
source, and is not injected into workers.

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

## Project Independence

Default roles should be engineering- or collaboration-level abstractions, not project
feature descriptions. A role such as `coder`, `explorer`, or `reviewer` should be usable
across repositories.

Put project-specific facts in one of these places instead:

- the task prompt;
- project-local instructions such as `AGENTS/`;
- normal templates when a recurring project-local procedure has proven reusable.

If you intentionally create a project-private role, mark it clearly in both the role
profile and the role description, for example `private: nameless-game skill tester`.
Private roles may encode project-specific vocabulary and constraints, but should not be
mistaken for generic roles.

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

Then create the orchestrator-facing profile:

```text
docs/role-profiles/explorer/README.md
```

The profile should briefly document:

- when to use the role;
- when not to use it;
- legal states and state-selection notes;
- available normal templates;
- expected output types;
- an orchestrator checklist for sending tasks.

Do not copy the full prompt files into the profile.

## Design Legal States

`running` and `exit` are mandatory. Add a state only when it gives the orchestrator
useful information or controls a meaningful protocol boundary.

Good states describe externally observable conditions, such as `investigating`,
`verifying`, or `blocked`. Avoid turning every checklist item into a state.

Do not design ordinary role states as a linear flow such as
`running -> inspecting -> verifying -> exit`. Legal states are a palette of observable
current-work labels. After `running`, the worker should choose the legal state that
matches its real current phase, and then end with confirmed `exit` when the assigned
work is genuinely done.

Only smoke/protocol-test roles should require a worker to visit several states in a
fixed order, and that requirement should live in a selected smoke task or
`normal_prompt`, not in a generic role contract.

For every custom state, the system prompt should say:

- when the worker enters it;
- what evidence or condition it represents;
- when it leaves it;
- whether `SummaryMessage` is expected.

The exit confirmation should test the role's ending obligations without assuming a
specific artifact such as `result.md`.

Prefer a dedicated system prompt file for state semantics, such as
`system_prompt/20-state-semantics.md`. Keep state definitions close to the role so the
worker knows what each state means and when to call `Update-WorkerState.ps1`.

Use a short header reminder, such as `header_prompt/10-state-reminder.md`, to remind the
worker to update lifecycle state without repeating the full state manual.

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

Normal templates may be more project-specific than the base role when the template is
selected explicitly and its name makes the scope clear. Still avoid hiding one-off task
facts in normal templates; if it is only useful once, keep it in the task prompt.

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
9. The role profile gives enough information for an orchestrator to choose the role
   without opening the prompt source files.

## Common Mistakes

- Encoding project paths or current feature details in the role.
- Asking the role to both gather evidence and make the orchestrator's final decision.
- Putting optional procedures in the always-injected system prompt.
- Using `normal_prompt` as an automatic task body.
- Adding states without defining when each state should be selected.
- Presenting ordinary role states as a required linear path instead of current-work
  labels.
- Making `result.md` or another fixed artifact part of the exit contract.
- Treating registration alone as proof that prompt injection and state validation work.
- Forgetting to create or update `docs/role-profiles/<role>/README.md`.
- Creating a generic-looking role that actually contains project-private assumptions.

## Storage And Sharing

Role directories and `prompt_templates/roles.json` are local runtime configuration and
are gitignored by default. A registered role is immediately usable on the current
machine but is not automatically distributed with the repository.

If roles should ship as built-in assets, define an explicit tracked role-pack location
or packaging/import mechanism rather than relying on local registration state.
