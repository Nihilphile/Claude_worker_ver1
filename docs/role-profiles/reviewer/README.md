# Reviewer

## Use When

Use `reviewer` when the orchestrator needs independent assessment of a completed
change, claimed fix, runtime behavior, test result, or report before accepting work.

This role is especially useful for shared contracts, process lifecycle, protocols,
persistence, runtime injection, cleanup behavior, output schemas, and difficult-to-see
runtime state.

## Do Not Use When

- The task is primarily unknown discovery.
- The implementation direction is not yet chosen and evidence gathering is needed.
- The worker should modify files to fix the problem.
- The goal is metadata curation rather than correctness assessment.

## States

`running`, `inspecting`, `reviewing`, `verifying`, `blocked`, `exit`

States are observable work stage labels, not a workflow graph. Only `running`
and confirmed `exit` are mandatory. After `running`, the reviewer should report
whichever legal state best matches the real current phase. Never require a
worker to visit every listed state unless the task is explicitly testing state
transitions.

State selection notes:

- Use `inspecting` while locating artifacts, claims, diffs, reports, tests, or
  logs.
- Use `reviewing` while evaluating correctness, risk, evidence, contracts, or
  regressions.
- Use `verifying` only when running allowed checks, reproducing a claim, or
  cross-checking a suspected finding.
- Use `blocked` when the assigned review cannot be completed inside scope.
- End with confirmed `exit` when the review report or blocker note exists.

## Normal Prompts

| Name | Use |
|------|-----|
| `focused-review` | Review one bounded artifact or behavior from scratch. |
| `regression-review` | Re-review a repair against prior findings. |

## Expected Outputs

- Review Report
- Blocker Report when the assigned review cannot be completed inside scope

## Orchestrator Checklist

Before sending a reviewer task, provide:

- the exact artifact, files, report paths, commands, or behavior to review;
- accepted baseline and prior findings, if any;
- allowed read roots and whether runtime commands are allowed;
- forbidden paths or actions;
- acceptance criteria or claimed behavior;
- required verdict scale if it differs from `PASS`, `PASS WITH RISKS`, `FAIL`;
- whether to use `-InjectNormal focused-review` or `-InjectNormal regression-review`.
