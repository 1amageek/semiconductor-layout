# M7: スケール・パリティ — ライブ検証を 10⁶ シェイプへ

## 目的

「100 万シェイプでもインタラクティブ」を**描画だけでなく検証の主張にする**。
M6 完了時点の検証済みスケールには 150 倍以上の開きがある:

| ライブ系 | 型 | 検証済みスケール | apply 実測 |
|---|---|---|---|
| 描画 (M6) | `LayoutRenderIndex` | **1,000,000** | 3µs |
| DRC (M1) | `IncrementalDRCSession` | ~6,400（80×80 fixture） | ~4ms |
| 接続性 (M3) | `LiveConnectivitySession` | 小規模 fixture | 0.23ms |
| 制約 (M5) | `LayoutConstraintChecker` | 小規模 fixture（毎編集フル再計算） | — |

M7 の完了条件は「**1M シェイプのドキュメント上で、1 編集あたりの全ライブ系応答（DRC + 接続性 + 制約 + 描画索引）の合計が 10ms 目標を満たし、かつ live == batch が維持されている**」こと。

## 非目標

- 検証アルゴリズム自体の意味論変更（ルールの追加・判定の変更はしない。規模耐性のみ）。
- 階層キャッシュ DRC（セル単位の結果再利用）— M10 以降の課題。
- マルチスレッド化 — まず単一スレッドで予算内に収める。並列化は予算が物理的に不足した場合の最終手段として別途設計する。

## 現状の構造と規模リスク

```
LayoutEditDelta
   │
   ├─ IncrementalDRCSession.apply ── クラスタ粒度の再判定
   │     └─ ShapeGridIndex（★不変・build-once）── 再構築が走る粒度が規模リスク
   │     └─ LayerDensityState ── ウィンドウ密度（dirty ウィンドウ限定か要計測）
   ├─ LiveConnectivitySession.apply ── LayoutUnionFind + ConnectivityContactIndex
   │     └─ 削除時の再結合コストが規模リスク（union-find は削除が苦手）
   ├─ LayoutConstraintChecker.check(document:cellID:) ── ★毎編集フル再計算
   │     └─ 制約数は少ないが、参照シェイプ解決が全シェイプ走査なら O(N)
   └─ LayoutRenderIndex.apply ── 規模実証済み（このパターンを輸出する）
```

`ShapeGridIndex`（LayoutVerify）は**不変**構造で、構築時に全 bbox を受け取る。
ライブ編集で 1M 規模を支えるには、M6 の `LayoutRenderIndex` で実証した
**可変一様グリッド + 増分 insert/remove** パターンが必要になる。

## フェーズ計画

### M7.0 計測（最初に必ず・推測禁止）

1M fixture（M6 ベンチマークと同型: 2µm ピッチの unit square グリッド + クリーンな via/宣言ネット）で以下を計測し、支配項を特定する:

| 計測点 | 何が分かるか |
|---|---|
| 各セッション `init`（document を開くコスト） | 10⁵→10⁶ のスケーリング次数 |
| 各セッション `apply`（1 シェイプ移動） | per-edit コストの O(N) 項の有無 |
| `apply` 内訳の `sample <pid>` プロファイル | 再構築している構造の特定 |

**M6 の教訓により、ここを飛ばして実装に入ることを禁止する。** 774s→1.5s の修正は、プロファイルが最初の推測（バケット CoW）を否定したから到達できた。

### M7.1 共通可変空間索引 `MutableShapeGridIndex`（LayoutVerify）

`LayoutRenderIndex` のグリッド管理部分を検証用に一般化した新型を `LayoutVerify` に追加する（`LayoutRenderIndex` 自体は描画集約を持つため共有しない。パターンの輸出であって型の共有ではない）。

```swift
/// Mutable uniform-grid index over shape bounding boxes.
/// Insert/remove are O(cells overlapped); queries return a superset
/// of true neighbours in deterministic order (caller keeps exact predicates).
struct MutableShapeGridIndex {
    init(boundingBoxes: [(id: UUID, box: LayoutRect)], cellSize: Double)
    mutating func insert(id: UUID, box: LayoutRect)
    mutating func remove(id: UUID)               // id→cells の逆引きを保持
    func neighbours(of box: LayoutRect, margin: Double) -> [UUID]
}
```

設計上の固定事項:

- **closed-interval セル範囲**を既存 `ShapeGridIndex` から継承する（接触ペアを必ず候補に含める既存保証を壊さない）。`LayoutRenderIndex` の half-open 規約とは**意図的に異なる**ことをコメントで明記する。
- insert/remove は **mutating メソッド内の直接ループ**で書く（visitor クロージャ禁止 — CoW 教訓）。
- 決定的順序（UUID canonical order — 既存 `UUIDCanonicalOrder` を使用）で候補を返し、live==batch の発火順序保証を維持する。

### M7.2 IncrementalDRCSession の規模耐性

- M7.0 で特定した O(N) 項を排除する。想定候補: dirty レイヤの `ShapeGridIndex` 再構築 → `MutableShapeGridIndex` の増分更新へ置換。
- `LayerDensityState`: dirty ウィンドウのみ再計算されることを 1M で実測確認。ウィンドウ重なり集計は M2 で直した union 意味論を保つ。
- クラスタ（`LayerShapeCluster`）の併合・分割が editing locality を保つことをベンチで確認する。

### M7.3 LiveConnectivitySession の規模耐性

- 追加は union-find 増分マージで O(α)。**削除**が問題: 現行の再結合戦略（クラスタ局所再構築）の再計算領域が 1M で有界であることを実測し、必要なら「影響 island のみ再抽出」へ局所化する。
- `ConnectivityContactIndex` の更新粒度を M7.1 の索引に揃える。

### M7.4 LayoutConstraintChecker の増分化

現行は毎編集フル再計算。制約数 C は小さい（数十）ため、計算量より**参照解決**を直す:

- 制約が参照するシェイプ ID → シェイプの解決を辞書アクセスにする（全シェイプ走査の排除）。
- delta に含まれる ID を参照する制約だけ再評価する `LiveConstraintSession`（M1/M3 と同形の `apply(_:) -> [LayoutConstraintViolation]`）。
- 影響しない編集では既存違反をそのまま返す（評価スキップを `stats` で申告 — silent skip にしない）。

### M7.5 統合ベンチマークと凍結

`LayoutEditorViewModel` に 1M ドキュメントを載せ、`commitDelta` 1 回で**全ライブ系が直列に走る**現実の編集 tick を計測する。

## 完了条件（DoD）

| 項目 | 目標 | 回帰キャップ（debug） |
|---|---|---|
| 全セッション init 合計（開くコスト） | ≤ 10s | < 60s |
| `commitDelta` 1 編集の全ライブ系合計 | **≤ 10ms（中央値）** | < 50ms |
| うち DRC apply | ≤ 5ms | — |
| うち接続性 apply | ≤ 2ms | — |
| うち制約 apply | ≤ 1ms | — |
| live == batch オラクル | DRC/接続性/制約とも multiset 一致 | 必須（キャップなし） |
| 既存 326 テスト | 全緑のまま | 必須 |

オラクルの規模運用: 1M でのフルバッチ比較は init コストが支配するため、**等価性は 10³–10⁴ の既存 fixture で網羅し、1M ではサンプル編集 N 回後のスポット比較**とする（比較自体の省略は不可）。

## リスクと対策

| リスク | 対策 |
|---|---|
| 密度ルールが本質的に広域（大シェイプ移動で多数ウィンドウが dirty） | dirty ウィンドウ数を stats に出し、上限超過時は「stale 申告」(`staleKinds` 既存機構) で正直に遅延評価 |
| union-find 削除の最悪ケース（巨大ネットの切断） | 再抽出領域 bbox を stats に出す。最悪ケースを fixture 化して回帰監視 |
| closed/half-open 規約の混在による off-by-one | 規約を型コメントに明記 + 境界一致 fixture（境界上の bbox）を両索引に対して持つ |
