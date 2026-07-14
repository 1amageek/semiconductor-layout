# semiconductor-layout goal status

## Baseline completed

- `CircuiteFoundation` is a local Swift Package Manager dependency.
- `LayoutCore.LayoutUnits` bridges to the validated
  `DatabaseUnitScale` boundary.
- The Foundation bridge is covered by the dedicated `LayoutCoreTests` suite.
- Existing deterministic import, hierarchy-safety, and exact-geometry changes
  remain in the working tree and are documented here.
- Package responsibilities and agent hand-off rules are documented in
  `README.md`, `DESIGN.md`, and `REQUIREMENTS.md`.

## Verification

Run from this package directory:

```bash
swift build
swift test
```

The parent integration task must record the exact test command and result after
all sibling packages are migrated. Foundry-scale signoff qualification remains
outside this package's baseline completion.

## Next implementation work

1. Migrate consuming engines to Foundation artifact/provenance types where
   their outputs cross package boundaries.
2. Add qualified technology-rule fixtures for exact DRC/LVS extraction.
3. Extend CLI artifacts with immutable run references supplied by the flow
   layer, without moving orchestration into this package.
