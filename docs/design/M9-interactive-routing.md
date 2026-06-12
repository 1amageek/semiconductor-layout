# M9: インタラクティブ配線 — スナップ・自動補完・push/shove

## 目的

商用 DRD（Virtuoso）体験の中核である**対話配線**を実装する。手で引くワイヤが、

1. 引いている最中から合法（幅・間隔・エンクロージャをリアルタイム遵守）
2. 障害物に当たれば**周囲のワイヤを規則内で押し退ける**（push/shove）か、正直に停止
3. コミットの瞬間に DRC/接続性/LVS/描画がすべて追従済み

になる。バッチ配線（`MazeRouter` / `DRCDrivenRoutingLoop` / `RipUpRerouter`）は自動 P&R の道具のまま残し、M9 はそれらの**部品を対話セッションに転用**する。

## 全体構造

```
 ポインタ tick
     │
     ▼
 InteractiveRouteSession（LayoutVerify — M2 DRDDragSession の兄弟）
     │  mode: .manual / .autoComplete / .shove
     │
     ├─ 経路候補生成
     │    .manual: 直交セグメント + スナップ（グリッド/既存形状エッジ/ピン）
     │    .autoComplete: 可視窓ローカル MazeRouter（既存 Lee/BFS を窓限定で再利用）
     │    .shove: 下記コリドー押し退け
     │
     ├─ 合法性: IncrementalDRCSession の enforce 二分探索（M2 実証済み）で
     │    「最後に合法だった位置」を常時保持
     │
     ├─ 層切替: via 挿入（ViaLandingRule 再利用、tech の合法スタックのみ）
     │
     └─ tick ごとに transient delta → 全ライブ系 apply（M1/M3/M5/M6/M8）
            │
            ▼
     commit → LayoutEditDelta → commitDelta（単一ストリーム）
     cancel → baseline 復元（M2 baseline-identity パターン）
```

## フェーズ計画

### M9.1 セッション骨格と手動配線 `.manual`

```swift
public struct InteractiveRouteSession {
    public init(
        document: LayoutDocument, cellID: UUID, tech: LayoutTech,
        net: UUID?, start: RouteAnchor    // pin / 既存シェイプ上の点 / 自由点
    ) throws
    public mutating func tick(to point: LayoutPoint) throws -> RoutePreview
    public mutating func switchLayer(to layer: LayoutLayerID) throws -> RoutePreview
    public mutating func commit() -> LayoutEditDelta
    public mutating func cancel()
}
```

- セグメントは直交（90°）から開始。45° は tech が許す場合のみ後続対応（`RoutePreview` に許容角度を申告）。
- スナップ優先順位: 同ネットピン > 同ネットシェイプエッジ > 配線グリッド。スナップ理由を `RoutePreview.snapReason` で返す（UI が根拠を表示できる）。
- 幅は tech の層既定幅。`RoutePreview` は**現在の合法終端**と**違反で止まった理由**（どのルール・どの相手）を必ず持つ。

### M9.2 合法性の常時維持

- M2 の `DRDDragSession` と同じ機構: tick ごとに transient delta を `IncrementalDRCSession` に当て、違反が出たら**二分探索で最後の合法位置へ後退**。
- 同ネットとの近接は違反でない（接続性 island を参照して同 island を除外 — M3 の `LiveConnectivitySession` を真実源にする）。
- ここまでで「障害物の手前で止まる正直な対話配線」が完成する。**shove なしでも出荷価値がある**ため、M9.2 完了を中間リリース点とする。

### M9.3 自動補完 `.autoComplete`

- ターゲット（ピン/ネットの最寄り island）を指定すると、**可視ビューポート + マージンの窓**に限定した `MazeRouter`（既存 Lee/BFS グリッド）で残区間を提案する。
- 窓限定の理由: 1M 文書で全域グリッドは作れない。窓内で見つからなければ「窓内不達」を**正直に返す**（窓を黙って広げ続けない。UI 操作で明示拡大）。
- 障害物は `ObstructionMap` を窓内で増分構築。M7 の `MutableShapeGridIndex` から窓内シェイプを取得する。

### M9.4 push/shove `.shove`

最難関。**コリドー方式**で有界に設計する:

```
 引いているワイヤ ──────▶ ████ 障害ワイヤ B（他ネット）
                          │ B を法線方向へ min 変位（spacing 充足分）動かす
                          ▼
                  B の移動が C に違反を作る → C も押す（連鎖）
                  連鎖は「コリドー予算 K セグメント」まで
```

- 押し退け対象は**同層の経路シェイプのみ**（via・ピン・インスタンスは押さない。固定物に当たったら shove 失敗）。
- 連鎖は BFS で展開し、累計 K セグメント（既定 8、オプション）を超えたら**shove 全体を放棄して `.manual` の停止挙動に退化**する。部分適用はしない（half-shoved 状態を作らない — 原子性）。
- 押された各ワイヤの変位も enforce 二分探索で合法位置に置く。移動は **ID 保存**（`moveShape` と同じ規約 — 下流の制約/LVS 参照を壊さない）。
- shove 結果も transient delta として全ライブ系に流れ、cancel で一括復元する。

### M9.5 編集面の統合

- 新ツール `LayoutTool.route`（既存ツールパレットへ追加）。
- tick 中の `RoutePreview` 描画（合法部=実線、提案部=破線、停止理由バッジ）。
- ショートカット: 層切替（via 自動挿入）、shove の入/切、自動補完の発火。
- すべての確定は `commitDelta` 1 回 = undo 1 単位（shove で動いた他ネットワイヤも同一 delta に含める）。

## 完了条件（DoD）

| 項目 | 基準 |
|---|---|
| 合法性 | commit 直後の `IncrementalDRCSession.commit()` がクリーン（または session が事前申告した違反と完全一致） |
| live == batch | commit 後の全ライブ系 == フル再計算（multiset） |
| shove の原子性 | 予算超過時に文書が baseline と bit-exact（fixture で検証） |
| shove の停止性 | 予算 K による有界性をワーストケース fixture（平行ワイヤ束）で検証 |
| 応答 | tick ≤ 16ms @ 1M シェイプ文書（M7 前提、窓ローカル処理のみ） |
| 接続正当性 | 配線完了で M3 の open が 1 つ消える / 誤ネット接触で short が出る fixture |

## リスクと対策

| リスク | 対策 |
|---|---|
| shove 連鎖の振動（A が B を押し、B の合法化が A を押し返す） | 連鎖 BFS は一方向（押し返し禁止）。解がなければ予算内でも失敗にする |
| 窓限定 maze の品質（窓外に良経路がある） | 「窓内最適」であることを RoutePreview に明記。全域探索はバッチ系の領分 |
| グリッド化コストが tick 予算を食う | ObstructionMap を窓キャッシュ + delta 無効化。tick あたり再構築禁止をベンチで固定 |
| 45° 対応のスコープ膨張 | M9 では 90° を DoD とし、45° は tech 能力宣言つきの後続 |
