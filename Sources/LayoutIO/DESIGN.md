# LayoutIO

## Purpose and Scope
Standard format adapters and canonical JSON persistence. Parent: [package](../../DESIGN.md).
Children: none introduced for this change.

## Responsibilities and Boundaries
Own coordinate and transform translation between canonical LayoutCore values
and standard LayoutIR values. Geometry algorithms and process via definitions
are owned by LayoutCore and LayoutTech.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Package](../../DESIGN.md) | parent | Standard-format composition | Developer and command IO | Preserve physical meaning across formats |
| [OASIS](../../../swift-mask-data/Sources/OASIS/DESIGN.md) | depends on | Standard signed PATH bytes and cell modality | Independent codec evidence | Exact pinned codec revision is required |
| [ViaPlacement](../../../swift-mask-data/Sources/LayoutIR/ViaPlacement/DESIGN.md) | depends on | Typed named via placement | DEF source semantics without fabricated paths | Verified immutable dependency must provide `IRElement.via` |
| [LayoutCore](../LayoutCore/DESIGN.md) | depends on | Coordinate-negation mirror flags | Canonical affine state | The mirror flag name alone does not establish axis semantics |
| [ViaGeometry](../LayoutCore/ViaGeometry/DESIGN.md) | depends on | Full local via placement | Persist all represented state | Standard via bridge remains explicitly incomplete |

## Architecture
```mermaid
flowchart LR
  Core[Canonical coordinates and affine state] --> Adapter[IRLayoutConverter]
  Adapter --> IR[Standard LayoutIR semantics]
  IR --> Formats[GDS OASIS DEF]
```

## Contracts and Invariants
Standard custom paths require both signed begin/end extension fields. They map
to canonical explicit micrometer distances and export as custom path records;
missing fields, nonfinite values and off-grid/overflow export fail before output.
Other path styles cannot carry ignored custom fields. OASIS import/export uses the verified codec revision with resolved endpoint distances and standard DBU per micrometer; omitted fields never reset extensions or borrow text/placement origins.

LayoutCore `mirrorX` negates the X coordinate; `mirrorY` negates Y.
LayoutIR `mirrorX` reflects about the X axis, negating Y before rotation.
Import maps that flag to canonical `mirrorY`. Export uses the XOR of canonical
mirror flags as the IR flag and adds 180 degrees to the angle when canonical
`mirrorX` is set. Both mirrors are therefore preserved, including array references.
Equivalent affine actions, rather than identical flag encodings, define preservation.

Canonical JSON persists full local via transforms. Standard via export rejects
local poses that the bridge cannot round-trip; its incomplete implementation
marker remains until every layer footprint and pose is preserved.

### Typed DEF via placement import

`IRElement.via` is a placement, independently of wire paths. LayoutIR owns its
source-DBU origin, exact master name, declared route layer, transform and source
route properties. LayoutIO resolves the master to exactly one explicit technology
via or contact definition before publishing a document. Missing or duplicate
masters, unresolved or conflicting route layers, ambiguous route fields, blank declared nets and
nonfinite/nonorthogonal/non-unit transforms fail with `LayoutIOError`.
DEF orientation reflects about the X axis before counterclockwise rotation;
the adapter maps this to canonical `mirrorY` in definition-local
`LayoutVia.geometryTransforms`. Source library units, master name and net binding
remain exact. Import emits one `LayoutVia` and no `LayoutShape` for each typed
placement; pad and cut geometry comes exclusively from the technology definition.
Route-layer ID/display aliases use the same case-insensitive comparison as DEF's
explicit layer-number mapping; the physical GDS number and master landing layer
must still match. Alias comparison never rewrites the source route annotation.

```mermaid
flowchart LR
  DEF[DEF named via at source DBU] --> IR[IRVia placement]
  IR --> Admission[Unique master and orthogonal pose admission]
  Tech[Explicit via or contact definition] --> Admission
  Admission --> Via[LayoutVia with local transform and net]
  Via --> Capture[Native pad / cut / contact capture]
```

| Input | Adapter guarantee | Behavioral evidence |
|---|---|---|
| Standalone named via | No synthetic wire or duplicate placement | Four actual native DEF placement coordinates |
| Source units and net | Exact DBU-to-micrometer conversion and net identity | Imported units, positions and declared net |
| DEF orientation | Local transform applied before placement | Eight orthogonal poses and asymmetric footprints |
| Explicit technology | Master-selected pads, cuts and contacts | Native conductor capture with no shape sources |
| Invalid placement | Typed failure before document publication | Missing/duplicate master and invalid pose/layer cases |

## Failure, Concurrency, and Constraints
Unsupported representation is a typed `LayoutIOError` before output creation.
These mappings operate on value-owned state with no shared mutable cache.

## Verification and Change Impact
`IRLayoutConverterTransformTests` compares actual imported/exported point mappings
for mirror combinations, quarter and arbitrary angles, single and array references.
`DocumentRoundTripTests` and command format tests execute DEF placement export
and import. Via rejection and canonical transform serialization have separate
behavioral tests. `PathExtensionRoundTripTests` additionally reads independent standard OASIS bytes, exports/reimports them and checks exact conductor bands through LayoutVerify. Geometry changes require reevaluating verification and LVS consumers.

[TypedViaPlacementIntegrationTests](../../Tests/LayoutIOTests/TypedViaPlacementIntegrationTests.swift)
imports the four actual native DEF named-only coordinates through the public byte
adapter, checks all eight orientation matrices against asymmetric native pad/cut
bands and contact topology, and rejects invalid placement before publication.
Normal and special routes retain their wire paths and produce exactly one via.
