# M8: ライブ LVS — 回路意図との常時照合

## 目的

M3 のライブ接続性は「宣言ネットの連続性」（短絡 = 1 island に 2 宣言ネット、断線 = 1 宣言ネットが複数 island）までを見る。M8 はその上に**トランジスタレベルの意図照合**を載せる:

> このワイヤを引いた瞬間・このポリゴンを伸ばした瞬間に、「レイアウトが表す回路」と「設計者が意図した回路（参照ネットリスト）」の差分が出る/消える。

バッチ signoff（Netgen LVS）は最終真実のまま残す。M8 はその**編集中の先行指標**であり、Netgen と判定が一致することをオラクルで保証する。

## 全体構造

```
                 LayoutEditDelta（単一編集ストリーム）
                        │
        ┌───────────────┤
        ▼               ▼
 LiveConnectivitySession   DeviceExtractionSession (M8.1 新規)
  islands/shorts/opens      poly∩diff → MOSFET {type, W, L, 端子島}
        │               │
        └───────┬───────┘
                ▼
        ExtractedNetlist (M8.2)          ReferenceNetlist (M8.2)
        （レイアウトが表す回路）          （.subckt 由来の意図回路）
                └───────┬───────────────────┘
                        ▼
              NetlistComparator (M8.3)
              決定的グラフ照合 + パラメータ照合
                        │
                        ▼
              LiveLVSUpdate (M8.4)
              unmatched devices / unmatched nets /
              parameter mismatches → キャンバスマーカー + 一覧
```

## フェーズ計画

### M8.1 デバイス抽出 `DeviceExtractionSession`（LayoutVerify）

ジオメトリから MOSFET を認識する。Sky130 の認識規則:

| 認識対象 | 規則 |
|---|---|
| チャネル | poly が diff を横断する交差領域 |
| 型 (NMOS/PMOS) | diff の well/implant 層コンテキスト（`LayoutTech` の層定義から解決） |
| W / L | 交差領域の diff 方向幅 / poly 方向長（矩形分解して合算） |
| S/D 端子 | チャネル両側の diff 残領域 → 接続性 island へ帰属 |
| G 端子 | poly island へ帰属 |
| B 端子 | well island（なければ基板既定）へ帰属 |

- 認識はクラスタ局所: delta の dirty 領域に poly/diff が含まれるときのみ該当クラスタを再認識する（M1 と同形）。
- **正解データはジェネレータが持っている**: `MOSFETCellGenerator`（LayoutAutoGen）が生成するセルは W/L/型が既知。抽出器のユニットオラクルは「生成パラメータ == 抽出パラメータ」。
- 非対応ジオメトリ（L 字チャネル等、矩形分解で表現できない形）は **`unrecognizedChannel` として違反扱いで申告**する。黙って無視しない。

### M8.2 ネットリストモデルと参照入力

```swift
/// A device-level netlist: the common currency of extracted and intended circuits.
public struct ComparisonNetlist: Hashable, Sendable {
    public struct Device: Hashable, Sendable {
        public var kind: DeviceKind          // .nmos, .pmos (将来 .resistor, .capacitor)
        public var terminals: [TerminalRole: NetID]   // .gate/.source/.drain/.bulk
        public var parameters: DeviceParameters       // W, L, multiplier
    }
    public var devices: [Device]
    public var ports: [String: NetID]        // 外部端子（宣言ネット名と対応）
}
```

- 抽出側: `ExtractedNetlist`（NetID = 接続性 island ID）。
- 参照側: `ReferenceNetlist`（NetID = 宣言ネット）。入力は **SPICE `.subckt` のサブセットリーダー**（`LayoutIO` に追加: M/X カードのみ、ニュートラルな素朴文法。circuit-studio への依存は作らない）と、テスト用のプログラマティック構築 API。
- MOSFET の S/D は電気的に対称 → 照合時は無順序ペアとして扱う（canonical 化で吸収）。

### M8.3 照合器 `NetlistComparator`

一般グラフ同型は不要。CMOS ネットリストには実用十分な**決定的反復精緻化**（Weisfeiler–Lehman 型 partition refinement）を使う:

1. 初期色: デバイス = (kind, パラメータ階級)、ネット = (ポート名 or 内部, 接続次数)。
2. 反復: 自分の色 + 隣接の (色, 端子役割) マルチセットで再ハッシュ。S/D は無順序。
3. 安定後、色クラスごとに抽出側と参照側の個数を突き合わせ。不一致クラスが**そのまま診断**になる（unmatched device / unmatched net）。
4. 色が一致しても W/L が許容差（既定 1%、tech 側で設定可能）を超えるものは `parameterMismatch`。

対称回路で色が縮退して 1:1 対応が決まらない場合は、**縮退をタイブレークせず「クラス単位で一致」と報告**する（誤った 1:1 マッピングの断定をしない — LVS 判定としては個数一致で十分）。

### M8.4 ライブ化 `LiveLVSSession` と編集面

- `apply(_ delta: LayoutEditDelta) throws -> LiveLVSUpdate`。内部で M8.1 の増分デバイス再認識 → デバイス集合かネットトポロジが変わったときだけ M8.3 を再実行（比較対象はデバイス数規模 ≈ 10³ なので毎回でもサブ ms、ただし無変化編集ではスキップし stats で申告）。
- `LayoutEditorViewModel` への配線は M3/M5 と同形: **commitDelta と transient 経路の両方**、undo/redo/navigate では rebuild。
- 表示: 専用 verdict チャネル（M3 の教訓 — DRC 違反リストに混ぜない）。unmatched デバイスはキャンバス上のチャネル領域をハイライト、unmatched ネットは該当 island を着色。

### M8.5 Netgen 一致ゲート

`LayoutIntegration.ExternalSignoffRunner` 経由で Netgen を起動できる環境では、trust fixture（inv / NAND / NOR / DFF / ACC-4 流用）に対して:

- ライブ LVS の pass/fail == Netgen の pass/fail
- 故意に壊した変種（ゲート未接続、S/D 入替、W 改変）で両者が同じ向きに fail

を CI ゲート化する（ngspice ゲートと同じ env-gated パターン。Netgen 不在時は**スキップを明示**し、golden 化した期待値で意味論テストは常時走らせる）。

## 完了条件（DoD）

| 項目 | 基準 |
|---|---|
| 抽出精度 | ジェネレータ既知セル全種で型/W/L/端子が正解一致 |
| live == batch | `LiveLVSSession` の判定 == ゼロから抽出+照合（multiset、ID 非依存） |
| Netgen 一致 | trust fixture + 故障注入変種で判定方向が一致 |
| 応答時間 | ACC-4 規模（~240 セル）で apply ≤ 5ms、1M シェイプ文書上でも編集 locality 維持（M7 索引前提） |
| 正直さ | 認識不能ジオメトリ・照合縮退・スキップした再照合がすべて結果に申告される |

## リスクと対策

| リスク | 対策 |
|---|---|
| 認識規則の PDK 依存（implant/well の層解釈） | 規則を `LayoutTech` 駆動にし、Sky130 以外は「未定義 tech では throw」（silent 既定値禁止） |
| S/D 対称性の取り扱い漏れで偽 mismatch | 無順序化を canonical 形の単体テストで固定（入替 fixture） |
| 精緻化の不動点が遅い縮退ケース | 反復上限 + 上限到達を申告。CMOS 実回路では数反復で安定（ベンチで確認） |
| 参照リーダーのスコープ膨張 | M/X カード以外は明示エラー。フル SPICE パーサは作らない（CoreSpice の領分） |
