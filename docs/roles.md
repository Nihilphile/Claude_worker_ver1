# Role System

`-Role` is a free-form label. When used with a **registered role**, manager injects the role's template files into the worker prompt. Without a registered role, it acts as a lightweight tag in the prompt header (`"You are a $Role agent"`).

## CLI Commands

| Command | Description |
|---------|-------------|
| `role register <name> -Files <path> ... [-Force]` | Register with template files. Conflict shows existing info; `-Force` overwrites. |
| `role update <name> -Files <path> ...` | Replace a role's template files. |
| `role list` | List all registered roles. |
| `role show <name>` | Show role details + full template content. |
| `role unregister <name>` | Remove a role and its template directory. |

## Using a Role

```powershell
# New agent — role template injected
& $tui send my-coder -Role coder-tdd -Prompt "Implement feature X"

# Mid-session role switch — same agent, different role, session preserved
& $tui send my-coder -Role reviewer -Prompt "Review the code you wrote"

# No -Role — no injection, plain session resume
& $tui send my-coder -Prompt "Continue working"
```

## Role Lifecycle

```
role register    → templates copied to prompt_templates/role/<name>/ + roles.json entry
role update      → templates replaced
role unregister  → templates deleted, registry entry removed
```

## Name Conflicts

Roles are shared across all orchestrators. Conflicts are surfaced, not silently overwritten:

```
[MANAGER] Role 'coder' already exists:
  Registered by : Dreamjiao
  Templates     : my-workflow.md
  Use -Force to overwrite, or choose a different name.
```

This naturally encourages naming conventions like `coder-tdd` vs `coder-explore-first`.

## Editing Default Templates

The default worker prompt is defined in `prompt_templates/default/`. Edit directly — no CLI needed.

| File | Injected as | Purpose |
|------|------------|---------|
| `system.md` | `--system-prompt-file` | Worker runtime contract. Compression-resistant. |
| `header.md` | Task prompt preamble | `~~ROLE~~` replaced with actual role name. |
