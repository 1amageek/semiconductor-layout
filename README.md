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
| `LayoutTech` | `LayoutTechDatabase`: layer definitions and design rules (JSON tech deck) |
| `LayoutVerify` | Verification kernels: DRC, connectivity/net extraction, device extraction (label-driven, Magic semantics), netlist comparison, design-intent constraints |
| `LayoutIO` | GDSII/OASIS import/export bridging to the layout IR |
| `LayoutEditor` | Interactive editing engine: edit-command API, incremental DRC, DRD drag legality, live connectivity, constraint checking, LOD rendering, goal commands with replay determinism |
| `LayoutAutoGen` | Automatic generation: cell generators, seeded SA placement, DRC-aware routing, gate-level place & route |
| `LayoutIntegration` | Host-app integration surface |

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
```
