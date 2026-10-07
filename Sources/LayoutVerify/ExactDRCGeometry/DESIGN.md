# Exact DRC Geometry

## Purpose and Scope
Parent: [LayoutVerify](../DESIGN.md). No children. Prepare immutable exact DRC
regions for original flattened source/occurrence entries. Derived-layer PATH
sources remain explicitly unsupported by their existing materializer contract.

## Responsibilities and Boundaries
Own primitive grid admission, aggregate PATH work admission, checked union and
explicit evaluation scale. Keep canonical document, technology, original PATH
values and electrical snapshot unchanged. Rule implementations consume prepared
coverage and original metadata; neither split source shapes nor UUID-only keys
represent preparation. Legacy boolean algorithms outside PATH preparation keep
their existing contract.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [LayoutVerify](../DESIGN.md) | parent / used by | DRC run and rule composition | Atomic prepared generation | All helpers use the same evaluation scale |
| [HierarchyCapture](../HierarchyCapture/DESIGN.md) | depends on | Bounded flattened occurrences and ranges | Preserve repeated source UUIDs | Attribute by occurrence and flattened index |
| [ConductorCapture](../ConductorCapture/DESIGN.md) | depends on | Actual coordinateUnits and original electrical facts | Half-grid PATH lattice | Do not replace electrical topology |
| [RectilinearPathProjection](../RectilinearPathProjection/DESIGN.md) | depends on | Integer stroke emitter | Single shared algorithm | Neutral failures map at consumer boundaries |
| [Mask geometry](../../../../swift-mask-data/Sources/MaskGeometry/RectilinearDecomposition/DESIGN.md) | depends on | Checked union budget and exact bands | Aggregate bounded PATH preparation | Ordinary unbounded booleans do not inherit this guarantee |
| [Exact DRC PATH tests](../../../Tests/LayoutAutoGenTests/ExactDRCPath/DESIGN.md) | verified by | Public run and independent RECT union | Actual source admission and rule behavior | Parent owns retained GDS integration |

## Architecture
```text
original flattened entry + capture coordinateUnits
    -> exact primitive admission -> shared stroke emitter
    -> one aggregate checked union budget -> immutable source Region
    -> explicit-scale DRC rules and staged antenna
original electrical snapshot -> connectivity verdict
```

## Contracts and Invariants
One prepared entry retains each original shape, flattened index and occurrence
index. Equal world geometry may share a coverage lookup, but original entries
and their metadata remain distinct. PATH regions may contain multiple boundaries
and union overlap once. Rule geometry conversion throws; missing or malformed
coverage cannot become an empty successful region. Rect-only rules assess the
whole source coverage, not individual emitted pieces.

Merged-rule attribution consumes original integer IREdgePair or Region bounds
on this same evaluation lattice and compares them with prepared source bounds.
Display LayoutRect reconstruction, minimum display spans and floating addition
cannot become exact attribution or source-admission authority. Contact with a
marker edge is inclusive. Source ordering and repeated occurrence metadata are
retained. Development keeps its exploratory bounding-box metadata inspection;
that inspection does not admit malformed polygons as physical geometry.

Exact staged antenna contact uses full-mask prepared shape regions and the
same snapshot's admitted pin bands and per-layer via bands. Pin lookup retains
sourcePinIndex and occurrence; via lookup retains flattened source index and
layer. Source values and occurrence ranges are checked before composition.
Centered pin bounds and transformed via geometry are not regenerated through
floating rectangles. Missing coverage fails explicitly. Integer bands reuse
the existing checked rectangle construction, within capture's admitted output
limits; no new projection or contact graph is created. Antenna retains its
boundary-inclusive edge/corner predicate and deposition stages rather than
substituting native electrical contacts, whose incidence semantics differ.
Device-aware shape replacements remain electrical facts; antenna still evaluates
the original full mask. Display/broad-phase boxes do not establish contact.
Broad-phase boxes derive from integer Region bounds with outward floating
conversion and checked enclosing maxima, preserving inclusive edge/corner
candidates in the existing closed-cell index. This display-only enclosure does
not change source admission or the integer contact predicate.

Evaluation uses actual captured coordinateUnits, including the established
half-grid refinement for odd PATH widths. Source and technology units remain
unchanged. Primitive and active geometric threshold conversion checks finite
values, lattice representation and Int32 range instead of rounding into success.
Signed caps and endpoint order are preserved. Unsupported derived sources retain
their prior blocking diagnostic before this preparation.

## State, Ownership, and Lifecycle
Prepared entries and coverage are immutable, invocation-local values. No global
cache or mutable shared state is introduced. One union budget spans all PATH
projections; a failed call retains spent work and returns no prepared generation.

## Failure, Concurrency, and Constraints
Existing hierarchy/decomposition policies bound raw points and generated pieces.
Generated rectangle entries are admitted before allocation against both the
decomposition input ceiling and the remaining aggregate union input ceiling.
Default union input/edge/output ceilings use the existing decomposition policy;
intermediate bands use its output ceiling and sweep work uses its edge ceiling.
Callers may supply all five explicit ceilings without resetting any per PATH.
The lower union policy additionally bounds intermediate bands, sweep work and
output. Shared cancellation is checked during projection and union.
Electrical capture receives the identical invocation predicate through geometric,
MOS and poly-resistor profile dispatch before exact preparation; no owner silently
substitutes Task cancellation when the caller provided a predicate.
Grid, range, cap, unsupported shape, exhausted budget and cancellation failures remain typed
failures. Ordinary region rule operations retain their existing scope.

| Target | Storage | Isolation | Mutation |
|---|---|---|---|
| Native / WASM / Embedded | Immutable run value; call-local inout budget | No shared mutable state | Same synchronous invocation-local preparation |

## Verification and Change Impact
ExactDRCPathTests own public DRC success, independent RECT differentials,
source/occurrence preservation, true width/spacing/antenna violations and atomic
grid/range/budget/cancellation/unsupported refusals. Existing native conductor
tests own unchanged capture behavior. The parent reruns the original 92 PATH
GDS with its unchanged canonical technology before candidate lifecycle evidence.
