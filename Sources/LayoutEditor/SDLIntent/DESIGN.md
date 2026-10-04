# SDL Intent

## Purpose and Scope
Own explicit label-to-net annotation and existing reference-device placement in
[LayoutEditor](../DESIGN.md). No children. This change concerns annotation;
placement continues to delegate to the existing generator and editor commands.

## Responsibilities and Boundaries
The caller requests annotation of the edit-target cell's label candidates, as
specified by the existing operation. This is not automatic interpretation of all
visual text or child labels. DeviceExtractor owns MOS channel preparation and
native physical contacts. Annotation owns admission and canonical mutation.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [LayoutEditor](../DESIGN.md) | parent | MainActor editing and error presentation | Single undoable command | Failure preserves the document |
| [Conductor capture](../../LayoutVerify/ConductorCapture/DESIGN.md) | depends on | Native component point query and pin incidence | Label authorization | UUIDs and envelopes cannot select electrical components |
| [Hierarchy capture](../../LayoutVerify/HierarchyCapture/DESIGN.md) | depends on | Source ranges and exact occurrence paths | Canonical source ownership | Repeated source UUIDs are not occurrence identity |
| [LayoutVerify](../../LayoutVerify/DESIGN.md) | depends on | Device-owned electrical context | Same MOS semantics as extraction/live verification | Raw geometric capture is not a MOS connectivity result |

## Architecture
```text
Requested root labels + canonical document + technology
  -> Device-owned deviceAwareMOS conductor snapshot
  -> exact native point coverage + source/pin/occurrence incidence
  -> complete mutation preflight -> one editor transaction
  -> same-context live analysis -> finish-net / goal result
```

## Contracts and Invariants
- Every point query uses the Device owner's public snapshot. Source geometry,
  shape UUID overlap and bounding boxes do not authorize a net assignment.
- Root shape/via assignment is valid only if all its native footprints belong
  to one selected component. A source spanning MOS slabs retains its original
  geometry and source-level net meaning; root pins or instance terminals carry
  the distinct component labels instead.
- Pins carry a name only when all their actual contacted components agree with
  that selected intent. Root source indices identify the original pin; child
  pins identify an exact captured occurrence path and terminal name.
- Direct child terminal binding must be representable by the canonical
  instance terminal table. Shared array entries must have the same requested
  name in every affected occurrence. Unavailable nested correspondence or
  contradictory shared entries fail explicitly; shared masters are not edited.
- Distinct requested names on one physical component fail atomically. All
  point queries and binding checks finish before the editor mutation begins.
- Direct annotation preserves the existing unmatched-label summary contract.
  Goal annotation requires all requested candidates to match and fails before
  mutation when any remain unmatched. The operation does not guess display
  text classification from names, layers or typography.

## Runtime Flows
Capture -> query each requested candidate -> resolve component names -> admit
whole-source and exact pin/terminal writes -> persist named nets in one undo
unit -> resynchronize live verification. Goal delegates to the strict operation.

## State, Ownership, and Lifecycle
The MainActor view model owns the editor. Captured snapshots and mutation
planning tables are invocation-local. The command creates no background tasks,
mutable global state, storage duplication or cross-target synchronization branch.

## Failure, Concurrency, and Constraints
Capture and query failures remain visible through the existing editor error
surface. Binding ambiguity uses SDLNetAnnotationError and returns no successful
summary. Unavailable nested binding remains an explicit unsupported branch.
Capture uses caller-selected LayoutConductorCaptureLimits; annotation's point
probe phase separately admits label-count times footprint-count against that
policy's maximumContactProbes, using checked integer arithmetic. This is an
admission ceiling, not large-design performance qualification.

## Verification and Change Impact
[SDLIntentTests](../../../Tests/LayoutAutoGenTests/SDLIntentTests.swift) owns
actual generated NMOS source/drain separation, preserved multi-piece source
meaning, scoped repeated-instance binding, strict unmatched and atomic conflict
refusal. Existing EditorDogfoodTests own annotation -> finish-net -> LVS -> GDS
reopen and goal replay. Changes to Device context, query-grid admission or
canonical terminal representation require those actual paths to be checked.
