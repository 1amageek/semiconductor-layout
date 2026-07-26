# semiconductor-layout Remaining Tasks

Updated: 2026-07-26

The Foundation bridge, deterministic layout behavior, exact geometry, and
typed extraction-deck readiness boundary are implemented.

## Remaining tasks

| ID | Priority | Owner | Task | Exit criteria |
|---|---|---|---|---|
| LAY-W1 | P2 | Workspace integration | Extend flow-owned run references while preserving the package's canonical Foundation artifact boundary. | Xcircuite consumers can bind layout outputs into run artifacts without duplicate artifact identity or orchestration logic in this package. |

## External prerequisites

Foundry-scale signoff qualification and approval are external evidence and
policy decisions.

## External P1 prerequisite

| Former ID | Owner | Required evidence |
|---|---|---|
| LAY-1 | Process/PDK evidence workflow | Process-provided technology rules and extraction decks with exact identity, positive/negative geometry, deterministic raw observations, and independent ToolQualification evaluation. The library already exposes the typed readiness and execution boundaries; it must not invent foundry assets. |

## Evidence reviewed

- `GOAL_STATUS.md`, especially `Next implementation work`
- `README.md`
- `DESIGN.md`
- `REQUIREMENTS.md`
- `Sources` incomplete-implementation marker scan
