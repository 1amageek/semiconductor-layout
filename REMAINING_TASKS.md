# semiconductor-layout Remaining Tasks

Updated: 2026-07-26

The Foundation bridge, deterministic layout behavior, exact geometry, and
typed extraction-deck readiness boundary are implemented.

## Remaining tasks

| ID | Priority | Owner | Task | Exit criteria |
|---|---|---|---|---|
| LAY-1 | P1 | semiconductor-layout | Add process-provided technology-rule fixtures for exact DRC and LVS extraction. | Fixtures retain exact process/deck identity, exercise positive and negative geometry, prove deterministic extraction, and produce raw observations suitable for independent ToolQualification evaluation. |
| LAY-W1 | P2 | Workspace integration | Extend flow-owned run references while preserving the package's canonical Foundation artifact boundary. | Xcircuite consumers can bind layout outputs into run artifacts without duplicate artifact identity or orchestration logic in this package. |

## External prerequisites

Foundry-scale signoff qualification and approval are external evidence and
policy decisions.

## Evidence reviewed

- `GOAL_STATUS.md`, especially `Next implementation work`
- `README.md`
- `DESIGN.md`
- `REQUIREMENTS.md`
- `Sources` incomplete-implementation marker scan
