# semiconductor-layout goal status

## Baseline completed

- `CircuiteFoundation` is a local Swift Package Manager dependency.
- `LayoutCore.LayoutUnits` owns a validated `DatabaseUnitScale` and cannot
  represent a non-finite or non-positive database-unit scale.
- The Foundation bridge is covered by the dedicated `LayoutCoreTests` suite.
- Deterministic import, hierarchy safety, and exact-geometry behavior are
  documented and covered by regression tests.
- Package responsibilities and agent hand-off rules are documented in
  `README.md`, `DESIGN.md`, and `REQUIREMENTS.md`.

## Verification

Run the package scheme with a 30-second per-test allowance. For a hard-bounded
matrix, run each of the seven test targets separately with a 120-second process
deadline:

```bash
xcodebuild \
  -scheme SemiconductorLayout-Package \
  -destination 'platform=macOS' \
  -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 30 \
  test
```

The migration verification covers `LayoutIOTests`,
`LayoutLVSExtractionTests`, `LayoutCoreTests`, `LayoutIntegrationTests`,
`LayoutAutoGenTests`, `LayoutEngineTests`, and `LayoutCommandsTests`. The
million-shape performance suite is an explicit opt-in test controlled by
`LSI_SCALE_1M=1`; it is not part of the bounded functional matrix. Foundry-scale
signoff qualification remains outside this package's baseline completion.

## Next implementation work

1. Migrate consuming engines to Foundation artifact/provenance types where
   their outputs cross package boundaries.
2. Add qualified technology-rule fixtures for exact DRC/LVS extraction.
3. Extend CLI artifacts with immutable run references supplied by the flow
   layer, without moving orchestration into this package.
