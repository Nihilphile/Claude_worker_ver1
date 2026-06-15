# Coder

## Use When

Use `coder` when the orchestrator has supplied a bounded implementation objective,
allowed scope, accepted baseline, and verification expectations.

## Do Not Use When

- The task is primarily unknown discovery.
- Architecture, protocol, persistence, or compatibility decisions are unresolved.
- The goal is independent review rather than implementation.
- The task only needs result curation or documentation indexing.

## States

`running`, `inspecting`, `questioning`, `coding`, `verifying`, `exit`

States are observable work stage labels, not a workflow graph. Only `running`
and confirmed `exit` are mandatory. After `running`, the coder should report
whichever legal state best matches the real current phase. Never require a
worker to visit every listed state unless the task is explicitly testing state
transitions.

State selection notes:

- Use `inspecting` while reading implementation context.
- Use `questioning` for a Question Pass or unresolved orchestrator decisions.
- Use `coding` while editing files.
- Use `verifying` while running checks or validating the edited behavior.
- End with confirmed `exit` after the requested artifact, report, or blocker
  note exists.

## Normal Prompts

| Name | Use |
|------|-----|
| `question-pass` | Inspect context and surface implicit decisions before implementation. No file edits. |

## Expected Outputs

- Incremental Work Report
- Question Pass Report
- Blocker Report

## Orchestrator Checklist

Before sending a coder task, provide:

- objective;
- allowed files or ownership boundaries;
- accepted baseline and prior report paths;
- implementation decision if already made;
- verification expectations;
- whether `-InjectNormal question-pass` is required.
