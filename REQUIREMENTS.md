# semiconductor-layout requirements

## Required baseline

- Build with Swift 6.3+ on macOS 26+.
- Keep `CircuiteFoundation` as the shared vocabulary dependency.
- Preserve deterministic, Codable, Sendable canonical layout state.
- Keep standard mask-data conversion available through `LayoutIO`.
- Return typed errors or structured diagnostics for invalid geometry, malformed
  hierarchy, unsupported exact geometry, and conversion failures.
- Keep development feedback and exact signoff semantics explicitly separate.
- Provide replayable command APIs for headless and Agent use.

## Foundation integration requirements

| Requirement | Acceptance condition |
|---|---|
| Unit boundary | `LayoutUnits(scale:)` and `validatedScale` use `DatabaseUnitScale` |
| Dependency direction | Foundation is depended on by domain targets; Foundation never imports layout targets |
| Domain ownership | Geometry, rules, extraction, and DRC result types remain in this package |
| Evidence readiness | Higher layers can attach Foundation artifact/provenance values without parsing log text |

## Explicit non-goals

- A `CircuiteProject` type or project-directory lifecycle.
- A universal request/result envelope for all layout operations.
- Foundry signoff claims without qualified rule data and exact kernels.
- Replacing layout-specific geometry with generic Foundation types.

## Agent hand-off definition

The package is ready for domain implementation agents when the package builds,
its focused tests pass, the README and design contract describe target
ownership, and each new feature has a typed boundary and reproducible fixture.
