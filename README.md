# semiconductor-layout

Layout IR, interactive editing, verification kernels, and automatic layout
generation. This package owns the physical-design truth of the workspace: the
DRC/extraction kernels here drive both the editor's live verdicts and the
standalone `DRCEngine`/`LVSEngine` GDS backends, so interactive and batch
verification cannot drift.

## Products

| Product | Responsibility |
|---|---|
| `LayoutCore` | Layout document model: cells, instances, shapes, layers, occurrence-exact flattening |
| `LayoutTech` | `LayoutTechDatabase`: layer definitions, layer rules, cut-count rules, and interconnect definitions (JSON tech deck) |
| `LayoutVerify` | Verification kernels: DRC including minimum-cut and overlap-short diagnostics plus verified repair deltas, connectivity/net extraction, device extraction (label-driven, Magic semantics), netlist comparison, design-intent constraints |
| `LayoutIO` | GDSII/OASIS/CIF/DXF import/export and DEF placement/routed-net import/export bridging to the layout IR, plus LEF/LYP/JSON technology profile loading |
| `LayoutEditor` | Interactive editing engine: edit-command API, incremental DRC, DRD drag legality, live connectivity, constraint checking, LOD rendering, goal commands with replay determinism |
| `LayoutAutoGen` | Automatic generation: cell generators, seeded SA placement, DRC-aware routing, gate-level place & route |
| `LayoutIntegration` | Host-app integration surface |
| `LayoutCommands` | Headless canonical layout edit commands and artifact-producing runner for Agent / CI use, including shape edits, instance add/move/rotate/mirror commands, and verified DRC fix-all sweeps from JSON technology profiles |
| `layout-command` | CLI entry point for replayable layout edit JSON requests, standard mask-data conversion, structured layout inspection, and connectivity diagnosis |

## Invariants worth knowing

- **Occurrence aliasing**: flattened child shapes share one source UUID across
  instance occurrences — never resolve flattened geometry by shape UUID; use
  occurrence-exact member footprints.
- **Live == batch**: incremental editor verdicts (DRC, connectivity) are verified
  bit-exact against full batch recomputation.
- **Seeded determinism**: a seeded RNG is only as deterministic as the collection
  order it draws from — randomized algorithms (SA placement) draw and accumulate
  over canonical ordered state, never over dictionary iteration order.

## Build & test

```bash
swift build
swift test
swift run layout-command --request Tests/LayoutCommandsTests/Fixtures/basic-layout-command-request.json --json
swift run layout-command --action-domain --json
```

## Developer CLI Workflow

Use `layout-command` as the headless developer entry point for replayable layout
edits. A request JSON must provide either an input document or a deterministic
`documentID` for a new document. Output paths are explicit so generated artifacts
are easy to inspect and clean up.

```bash
swift build --product layout-command
LAYOUT_BIN="$(swift build --show-bin-path)/layout-command"
"$LAYOUT_BIN" \
  --request Tests/LayoutCommandsTests/Fixtures/basic-layout-command-request.json \
  --json
```

The same CLI also exposes standard layout artifacts without going through UI
state. Use `--convert-document` to move between canonical `LayoutDocument` JSON
and supported mask-data / placement formats, and `--inspect-document` to produce
a machine-readable summary. Non-JSON formats require an explicit technology
profile through `--tech`; the profile is data (`LayoutTechDatabase` JSON,
IRTechLibrary JSON, LEF, or KLayout LYP), not Swift source. DEF support covers
component placement plus regular NETS and SPECIALNETS routed paths: components
round-trip as instances with macro placeholder cells, route paths become
net-assigned `LayoutShape` paths, and route via names become net-assigned
`LayoutVia` elements when either the technology profile or the input DEF `VIAS`
section declares a matching via definition. File-local DEF via definitions are
loaded as effective technology for import, inspection, verification, and export;
their layer rectangles are preserved on `LayoutViaDefinition.layerGeometries`.
Native DRC and connectivity use that explicit via geometry for cut-count
minimum-cut checks, via enclosure coverage, batch opens, connectivity
extraction, and live connectivity sessions, so a via's bounding box is not
treated as a sufficient electrical contact.
Unknown route via names stay in route metadata for export but are not treated as
physical connectivity. Detailed-route signoff semantics such as nondefault
rules, timing, broader anisotropic rule families, and foundry-scale DEF corpus
qualification remain separate capability milestones.

```bash
"$LAYOUT_BIN" \
  --convert-document \
  --input layout.json \
  --input-format json \
  --output layout.gds \
  --output-format gds \
  --tech tech.json \
  --json

"$LAYOUT_BIN" \
  --inspect-document \
  --input layout.gds \
  --input-format gds \
  --tech tech.json \
  --json
```

Connectivity gets its own diagnosis verb. `--diagnose-connectivity` runs the
batch net extraction used by verification (the engine the editor's live
verdicts are checked against) and reports, per declared net, whether it is
whole — and for every open net, exactly where the disconnected geometry sits.
A technology profile is required for every input format, including JSON,
because the extraction needs layer and via semantics:

```bash
"$LAYOUT_BIN" \
  --diagnose-connectivity \
  --input layout.json \
  --input-format json \
  --tech tech.json \
  --json
```

The JSON envelope (`LayoutConnectivityDiagnosisResult`, sorted keys) contains:

| Field | Purpose |
|---|---|
| `status` | `passed` when the design has no opens and no shorts, `failed` otherwise |
| `inputPath` / `inputFormat` / `technologyPath` / `inputSHA256` / `inputByteCount` | Input evidence, as in `--inspect-document` |
| `diagnosis.topCellID` | Cell the analysis flattened (document top cell, or first cell) |
| `diagnosis.totals` | `netCount`, `extractedNetCount`, `openCount`, `shortCount` |
| `diagnosis.nets[]` | Per declared net: `netID`, `name`, `islandCount` (0 = no geometry, 1 = connected, ≥2 = open), `isOpen`, `pinCount`, `footprintCount` |
| `diagnosis.opens[]` | Per open net: `islands[]` with per-island `boundingBox`, `shapeCount`, `viaCount`, and occurrence-exact `footprints[]` (`layer` + `boundingBox`); plus `flylines[]` (`fromIslandIndex`, `toIslandIndex`, `start`, `end`, `length`, `startLayers`, `endLayers`) forming a minimum spanning tree of suggested connections |
| `diagnosis.shorts[]` | Conductor pieces carrying two or more declared nets: `nets[]` (`netID` + `name`), `region`, `shapeCount`, `viaCount` |

Exit codes are part of the contract so agents can branch without parsing:
`0` when fully connected (no opens, no shorts), `2` when opens or shorts are
present (the full JSON report is still printed), `1` on error (unreadable
input, missing `--tech`, and so on) with the standard structured failure
output.

Successful JSON output includes:

| Field | Purpose |
|---|---|
| `status` | `passed` when all commands replayed |
| `appliedCommands` | Ordered command audit trail |
| `outputDocumentPath` | Canonical `LayoutDocument` JSON |
| `outputDocumentSHA256` | Stable digest for reproducibility |
| `artifactManifestPath` | Manifest for generated layout/result/repair artifacts |

Standard format conversion output includes:

| Field | Purpose |
|---|---|
| `inputFormat` / `outputFormat` | Explicit source and target format contract |
| `technologyPath` | Profile used to map layers and vias |
| `outputSHA256` / `outputByteCount` | Artifact integrity for downstream DRC/LVS/PEX |
| `summary` | Document/cell/layer counts and bounding boxes for Agent inspection |

Verified DRC repair is also a command, not a UI-only action. A
`fixAllViolations` command reads a `LayoutTechDatabase` JSON file from
`technologyPath`, applies only verified repair deltas, and writes a
`LayoutRepairSweepReportJSON` artifact to `reportPath`. The report records
applied repairs, residual violations, and residual reason codes so developers
and Agents can decide the next manual or routing step from the same data.

Failure behavior is part of the developer contract. With `--json`, failures are
machine-readable and no output artifacts are written after validation fails:

```json
{
  "schemaVersion": 1,
  "status": "failed",
  "errorCode": "missing_document_id_for_new_document",
  "message": "documentID is required when inputDocumentPath is not provided"
}
```

Run the workspace-level CLI check before changing command schemas or executable
behavior:

```bash
../scripts/check-developer-cli.sh
```

The check builds `layout-command`, runs a successful request through the real
executable, validates JSON output and artifact paths, then runs an invalid
request to confirm JSON failure output and artifact hygiene.
