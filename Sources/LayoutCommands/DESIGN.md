# LayoutCommands

## Purpose and Scope
Typed layout commands and inspection/diagnosis artifacts. Parent:
[package](../../DESIGN.md). This change owns the connectivity diagnosis consumer
contract; mutation and file I/O remain with their existing command owners.
Children: none.

## Responsibilities and Boundaries
Consume native connectivity verdicts without inferring geometry or flattening
declared nets again. Retain artifact interpretation and scoped names in CLI
output. Native capture owns electrical contacts and terminal resolution.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Package](../../DESIGN.md) | parent | Typed command composition | Developer/agent entry points | Preserve exact input evidence |
| [LayoutVerify](../LayoutVerify/DESIGN.md) | depends on | Scoped connectivity verdicts and owned snapshot | One electrical producer | UUID alone is not a scoped net |
| [HierarchyCapture](../LayoutVerify/HierarchyCapture/DESIGN.md) | depends on | Occurrence path, source cell, parent bindings and pin ranges | Serialized scope interpretation | Numeric occurrence indices are capture-local |

## Architecture
```text
Input artifact + document + technology -> native batch analysis
  -> scoped net/pin counts + owned occurrence/pin interpretation table
  -> schema v3 diagnosis -> JSON output and pass/fail exit status
```

## Contracts and Invariants
Schema v3 uses the existing native NetReference in rows, opens and shorts.
The report records document ID, root cell ID and the native occurrence table;
the result envelope retains digest-verified input evidence. Occurrence indices
resolve through that table to instance/array paths, source cells and parent
bindings. Names are looked up in the resolved owning occurrence's source cell.
Repeated child-local UUIDs do not merge rows, pin counts or open diagnoses.

The report owns captured source pins in hierarchy order. Open pin indices are
lowered from native pin facts to this owned table, retaining each source UUID
and occurrence through pin ranges. They never address an unrelated snapshot.
These pins describe source identity and display extents, not electrical contact
geometry; native full pin bands alone establish contacts. Isolated pins produce
failed diagnoses even with zero islands or flylines. Root editing selectors use
the native root occurrence rather than UUID projection across all occurrences.

## Failure, Concurrency, and Constraints
Diagnosis is synchronous and call-local. Native typed admission failures
propagate to the existing structured CLI failure path. No substitute electrical
results, mutable shared cache or external process is introduced.

## Verification and Change Impact
[LayoutConnectivityDiagnosisTests](../../Tests/LayoutCommandsTests/LayoutConnectivityDiagnosisTests.swift)
owns actual CLI JSON decode/encode, scoped repeated-net rows and isolated-pin
failure/source identity. Native contract changes require this serializer and
diagnosis pass/fail controller to be checked together.

Inspection and diagnosis explicitly select the shared Device electrical context
when representing MOS electrical nets. Reports retain that context and scoped
hierarchy evidence. Unsupported capture/preparation is a structured failed
inspection; it must not become empty connectivity counts.
