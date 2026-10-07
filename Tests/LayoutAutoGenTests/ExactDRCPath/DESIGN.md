# Exact DRC PATH Tests

## Purpose and Scope
Test owner for [Exact DRC Geometry](../../../Sources/LayoutVerify/ExactDRCGeometry/DESIGN.md)
and the shared [integer projection](../../../Sources/LayoutVerify/RectilinearPathProjection/DESIGN.md).
The SwiftPM module is LayoutAutoGenTests. Parent composition is
[LayoutVerify](../../../Sources/LayoutVerify/DESIGN.md); no children.

## Responsibilities and Boundaries
Exercise public exact DRC success, real rule failures and atomic admission refusal.
Independent RECT unions supply the geometric oracle; no test stroke emitter is copied.
Native capture retains its separate existing behavioral suite. Parent integration owns
the retained 92-PATH GDS lifecycle. This suite makes no foundry qualification claim.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Exact DRC Geometry](../../../Sources/LayoutVerify/ExactDRCGeometry/DESIGN.md) | verifies | Atomic prepared coverage and actual evaluation lattice | Public run plus independent coverage oracle | Source values remain unchanged |
| [Conductor Capture](../../../Sources/LayoutVerify/ConductorCapture/DESIGN.md) | depends on | Canonical hierarchy, half-grid and electrical facts | Actual public native capture | No mock topology |

## Architecture
```text
original PATH -> public native capture -> exact DRC -> rule verdict/source evidence
independent RECTs -> integer region union ---------> differential coverage
invalid input/budget/cancel -----------------------> explicit refusal
```

## Contracts and Invariants
Caps, reversal, orthogonal miter and odd widths preserve coverage. Repeated source
UUIDs remain distinct flattened occurrences. Real width, spacing and staged antenna
violations retain source IDs. Unsupported, grid, range, threshold, aggregate budget
and cancellation cases cannot return successful prepared generations.
The non-Task cancellation regression measures the first hierarchy traversal and
transitions at the next electrical capture checkpoint for all three qualified
profiles. A typed hierarchy/native cancellation must precede exact projection;
no completed DRC result or source snapshot is published.
Captured pin and per-layer via contact are exercised through exact public
runChecked with independent edge and corner placement. Analytical areas and a
late upper-layer discharge distinguish antenna's inclusive incidence and stage
activation from native electrical contact semantics. Source IDs remain original.

## State, Ownership, and Lifecycle
All fixtures, documents, regions and inout budgets are test-local values. There are
no shared files, global mutable fixtures or target-dependent isolation branches.

## Verification and Change Impact
ExactDRCPathTests uses public runChecked and the actual canonical native capture.
Internal prepared values are inspected only to compare geometry and ownership that
the public verdict alone cannot distinguish. Root owns one stable build/runtime
batch and the original retained-GDS integration after lower Mask proof.
