# MOSFETGenerationTests

## Purpose and Scope

Isolated CPU Swift Testing target for the public MOSFET generation contract.
Parent: [MOSFETGeneration](../../Sources/LayoutAutoGen/MOSFETGeneration/DESIGN.md).
No children. The package owner controls target registration and execution.

## Responsibilities and Boundaries

Refute incomplete or incorrectly enclosed gate cuts using actual technology
rules. Check public Device extraction/capture and GDS export/import rather than
private generator helpers. Numerical PEX and host integration are upper-owner
verification responsibilities.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [MOSFETGeneration](../../Sources/LayoutAutoGen/MOSFETGeneration/DESIGN.md) | parent | Gate geometry and device identity | Behavioral contract under test | Preserve exact cut and channel dimensions |
| [LayoutVerify](../../Sources/LayoutVerify/DESIGN.md) | depends on | Device extraction and native snapshot | Actual electrical facts | Enclosure is checked independently of connectivity |

## Architecture

```text
public generator -> raw rectangle/enclosure assertions
                 -> public Device extraction
                 -> GDS bytes -> public import -> public Device capture/extraction
```

## Contracts and Invariants

Cover NMOS/PMOS, nf=1/3 and L below/equal/above the contact landing width. A
0.18-um gate with a 0.22-um cut is the minimal former-generator counterexample.
Each emitted gate cut must retain exact configured dimensions, full bottom/top
coverage and declared enclosures. New landings and exterior terminal spines must leave channel W/L/nf and
four distinct terminal identities intact. GDS boundary polygons are accepted
only when their exact vertices and edges form an axis-aligned rectangle; generic
bounding boxes are not geometry evidence. Polygon corners are checked against
original vertex extrema before creating a rectangle view. Cut dimensions are
compared as exact endpoint differences in the document's public DBU scale, after
coordinate admission within the scale's floating-point representation slack;
size-relative epsilon comparisons are not dimensional evidence. A dedicated outside-ACTIVE landing
is distinguished from a wide original gate strip that also encloses the cut. Missing or invalid required gate rules fail explicitly.

## State, Ownership, and Lifecycle

Each test owns its generated values and standard bytes; no persistent fixture,
global mutable state or shared file path is used.

## Failure, Concurrency, and Constraints

Pure CPU tests run with an external timeout and a caller-admitted dependency lock.
The target does not run UI or Metal tests. Parameterized test cases are counted
separately from registered method identities in retained execution evidence.

## Verification and Change Impact

MOSFETContactEnclosureTests owns the minimal red and the complete local contract.
Upper inverter consumers must separately regenerate and requalify their baseline.
