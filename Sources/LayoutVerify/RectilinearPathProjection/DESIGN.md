# Rectilinear Path Projection

## Purpose and Scope
Parent: [LayoutVerify](../DESIGN.md). No children. Own the single integer
orthogonal flat-cap stroke emitter consumed by Capture and exact DRC.

## Responsibilities and Boundaries
Project admitted original coordinates, width and ordered signed caps into
segment rectangles and square miter joins. Consumers own coordinate admission,
aggregate allocation budgets, union and source/occurrence attribution. No
Capture-specific error or electrical semantics belong to this component.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [LayoutVerify](../DESIGN.md) | parent | Invocation-local preparation | Shared algorithm owner | No shared mutable state |
| [PathGeometry](../../LayoutCore/PathGeometry/DESIGN.md) | depends on | Original path and ordered cap values | Canonical micrometer inputs | Do not use a floating outline as integer admission |
| [ConductorCapture](../ConductorCapture/DESIGN.md) | used by | Streamed integer rectangles | Existing native contact coverage | Preserve public Capture failure mapping |
| [ExactDRCGeometry](../ExactDRCGeometry/DESIGN.md) | used by | Same streamed rectangles | Bounded union per source | Preserve original source metadata |
| [Exact DRC PATH tests](../../../Tests/LayoutAutoGenTests/ExactDRCPath/DESIGN.md) | verified by | Independent RECT union | DRC consumer behavior | Native Capture tests retain their separate public failure proof |

## Architecture
```text
original primitives -> caller coordinate predicate -> Int32 primitives
    -> checked Int64 caps/segments/joins -> checked positive Int32 rectangles
    -> caller-owned union and attribution
```

## Contracts and Invariants
Width has an exact integer half on the caller's selected lattice. Primitive
coordinates and cap distances are admitted before arithmetic. Signed begin/end
distances retain original endpoint order. Rectilinear nonzero segments and
square miters retain union coverage. Circular caps, diagonals, reversals and
retractions entering an adjacent miter require explicit refusal. Projection
does not round, clamp, infer cap meaning or publish a replacement path.

## State, Ownership, and Lifecycle
All values and counters are call-local. The emitter streams rectangles and
allocates no outline. Consumers retain complete source and occurrence identity.

## Failure, Concurrency, and Constraints
Neutral typed errors distinguish invalid integer geometry, unsupported geometry
and cancellation. Coordinate/callback failures propagate. Cancellation is
checked per segment; callers bound original points and generated pieces before
allocation. Failure cannot publish a complete consumer generation.

## Verification and Change Impact
Existing ConductorPathCaptureTests preserve native coverage and public failures.
ExactDRCPathTests compare independent RECT coverage, caps, reversed paths,
miters, odd widths and explicit refusal. Changing this algorithm requires both
consumers' focused evidence; build/runtime/commit are parent-owned.
