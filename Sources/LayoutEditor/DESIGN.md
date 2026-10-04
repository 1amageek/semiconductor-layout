# LayoutEditor

## Purpose and Scope
Own interactive document commands and live verification. Parent:
[package](../../DESIGN.md). This contract covers electrical annotation and
verification consumers; renderer geometry and file persistence remain separate.

## Responsibilities and Boundaries
MainActor owns editor state and synchronous live sessions. LayoutVerify owns
Device preparation, native contacts and scoped electrical facts. Source UUIDs
select highlights; native pin/source occurrence facts authorize net mutations.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Package](../../DESIGN.md) | parent | Document command composition | Interactive entry point | Persist canonical document separately |
| [LayoutVerify](../LayoutVerify/DESIGN.md) | depends on | Explicit Device electrical context | Same producer for annotation and verification | Raw geometric capture is not a MOS net graph |

## Architecture
```text
Document + technology -> Device-owned native electrical context
  -> exact component/pin incidence -> scoped root/terminal mutation
  -> live connectivity + DRC + LVS -> trust state
```

## Contracts and Invariants
Annotation selects native band point coverage and original pin incidence.
It writes a whole shape/via net only when all its native pieces belong to one
component; otherwise it binds the exact root pin or recorded instance terminal
path. Missing/ambiguous path authority fails visibly. Connectivity, DRC and
finish-net use the same explicit Device context and retain its provenance.

## State, Ownership, and Lifecycle
The MainActor view model owns canonical editing and each single-owner live
session. Immutable native analyses may be shared. Failed preparation invalidates
trust instead of leaving an unmarked successful old verdict.

## Verification and Change Impact
[EditorDogfoodTests](../../Tests/LayoutAutoGenTests/EditorDogfoodTests.swift)
executes annotation, routing, LVS and standard-format reopen. SDL intent and
live verification fixtures detect scope/path failures and failed preparation.
Changing Device context or pin-source lifetime requires those actual paths.

Grid quarter-turn editing admits source coordinate operands individually at the
current native coordinate scale, executes the existing LayoutGeometry rotation
on integer lattice coordinates, then converts back once. It preserves source
geometry kind and ID; rounding drift is not sent into native recapture. Missing
current Device context, non-grid operands and integer overflow reject before
publication. The continuous LayoutCore rotation API is unchanged.

On-demand DRC without an admitted live generation uses checked Device-aware
verification. Capture failure retains only visibly stale prior violations and
surfaces the typed failure; gesture completion cannot clear that stale status.

Grid rectangle creation admits its edited endpoints before subtracting them on
the integer lattice. Source spans are converted to micrometers once; floating
endpoint subtraction cannot generate an off-grid electrical source. Admission
failure occurs before the rectangle is added to canonical state.
