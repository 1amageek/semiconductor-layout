# MOSFETGeneration

## Purpose and Scope

Own public MOSFETCellGenerator geometry for single- and multi-finger MOS devices.
Parent: [LayoutAutoGen](../DESIGN.md). No children.

## Responsibilities and Boundaries

Use explicit technology contact dimensions and enclosures to generate gate
landings outside channel ACTIVE. Preserve channel width, length, finger count
and source/drain/gate/bulk terminal meaning. Own the single-layer multi-finger
terminal spines required to keep those four terminals electrically distinct. This component does not alter PEX
cut laws, mesh resolution, calibration or already-generated master artifacts.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [LayoutAutoGen](../DESIGN.md) | parent | Public generator composition | Native Swift module | No public API relocation |
| [LayoutVerify](../../LayoutVerify/DESIGN.md) | depends on | Device-owned channel separation and capture | Independent topology and parameter interpretation | Positive-area contact is weaker than full enclosure |
| [Tests](../../../Tests/MOSFETGenerationTests/DESIGN.md) | used by | Generated cell geometry | Behavioral proof owner | Test the public generator and imported standard bytes |
| [PEX SheetExtraction](../../../../PEXEngine/Sources/PEXNative/SheetExtraction/DESIGN.md) | used by | Completely covered individual cuts | Quantitative full-cut admission | Geometry repair must preserve that law |

## Architecture

```text
parameters + contact rules -> admitted context -> channel/source/drain geometry
                                               -> gate cut + POLY landing + M1 landing/bus
                                               -> unchanged terminal roles and device labels
```

## Contracts and Invariants

Every gate CONTACT retains the declared CONT_POLY cut width and height. POLY
covers the entire cut and its declared bottom enclosure; M1 covers the cut and
its declared top enclosure. Both landings use outward manufacturing-grid
boundaries, never rounding a minimum enclosure inward. Gate POLY landings
overlap the channel's existing POLY extension with positive area and remain
outside channel ACTIVE. The original gate strip through ACTIVE keeps the
requested grid-admitted W/L and each finger's device identity. Single- and
multi-finger paths share the same landing construction responsibility. Multi-finger
source fingers extend to a spine below ACTIVE; drain fingers extend to a spine
above ACTIVE. Each spine clears all opposite-terminal fingers by the admitted M1
spacing. Gate metal lies beyond the spine on its gate side, and the bulk tap lies
beyond the spine on the opposite side. Horizontal spines never cross opposite
fingers inside ACTIVE. Channel geometry and alternating source/drain identity
remain unchanged.

Gate rules must exist, name the expected CONTACT/POLY/M1 materials and provide
finite positive cut dimensions, nonnegative finite enclosures and a finite
positive manufacturing grid. Exact cut dimensions must be representable on that
grid; geometry or rule combinations that cannot preserve the gate contract
fail with typed generation errors rather than omit a gate cut or use guessed
enclosures. Existing parameter/finger-count admission remains in its owner.

## Runtime Flows

Admit parameters and rules; construct the existing channel geometry; place
exact gate cuts outside ACTIVE; derive their enclosing POLY and M1 landings;
connect alternating source/drain fingers through separate exterior M1 spines;
connect multi-finger M1 landings through the exterior gate bus; publish the generated cell.

## State, Ownership, and Lifecycle

All context, geometry arrays and terminal records are local to generation.
The returned LayoutCell owns its geometry. No shared state, conditional
synchronization, I/O or asynchronous lifetime is introduced.

## Failure, Concurrency, and Constraints

Missing rules and unrepresentable geometry propagate typed AutoGenError failures.
Work and shape count remain linear in the existing bounded finger/contact count.
One POLY landing per gate is sufficient; no meshing or geometry repair loop is
performed. Generation publishes no partially successful cell.

## Verification and Change Impact

The isolated [MOSFETGenerationTests](../../../Tests/MOSFETGenerationTests/DESIGN.md)
owns cut dimensions, both enclosures, full cut area, NMOS/PMOS, nf=1/3 and gate
lengths below/equal/above the required landing width. Device extraction must
retain channel W/L/nf and terminal topology before and after GDS roundtrip.
Upper owners requalify newly generated inverter masters, characterization and
full-mask PEX/LVS; old failing bytes remain evidence of the former generator.
