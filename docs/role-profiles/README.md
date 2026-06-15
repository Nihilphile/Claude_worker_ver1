# Role Profiles

This directory is the orchestrator-facing role catalog.

Role profiles are not prompt source files and are not injected into workers. They are
short usage notes for the orchestrator before choosing a role, state labels, and
optional `-InjectNormal` fragment.

Each registered role should have:

```text
docs/role-profiles/<role>/README.md
```

Keep profiles brief. Link to deeper design docs or worker reports instead of copying
prompt text.

## Current Profiles

| Role | Use |
|------|-----|
| [coder](coder/README.md) | Bounded implementation after the orchestrator has supplied scope and acceptance criteria |
| [explorer](explorer/README.md) | Targeted evidence gathering when implementation depends on unresolved facts |
| [reviewer](reviewer/README.md) | Independent assessment of completed work, evidence, risks, and acceptance blockers |
| [test](test/README.md) | Smoke-test role for exercising role-system features |
