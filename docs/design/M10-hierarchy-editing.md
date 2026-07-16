# M10: 階層編集 — edit-in-place / インスタンス操作 / 配列（AREF）

## 目的

階層を**閲覧の単位**から**編集の単位**へ引き上げる。現状の能力と不足:

| 能力 | 現状 |
|---|---|
| インスタンス参照モデル | `LayoutInstance {cellID, transform, terminalNetIDs}` — 変換は translation/rotation/magnification/mirror 完備 |
| セル間ナビゲーション | `openCell` / `openSelectedInstanceCell` / `navigateBack` あり（DFS 循環ガード済み） |
| インスタンス CRUD | `LayoutDocumentEditor.addInstance/removeInstance` のみ（編集コマンド未統合） |
| インスタンスの move/rotate/mirror | **なし**（シェイプ動詞のみ） |
| edit-in-place | **なし**（子セル編集は子セルへ移動して行う） |
| 配列インスタンス | **なし** — `LayoutInstance` に repetition フィールドが存在しない |
| GDS AREF | swift-mask-data の reader/writer は AREF レコード対応済み。`LayoutIR` 経由で編集モデルに来る際の扱いは展開（要 M10.0 確認） |

## 設計の要：flatten がファンネルである

全ライブ系（M1/M3/M5/M6/M8）は `flattenedDocumentShapes()`（アクティブセルの平坦化）だけを見る。**階層編集は flatten への入力を変える操作**として設計すれば、検証側は一切変更不要になる:

```
 子セル空間での 1 編集（EIP）
        │ インスタンスパス変換 T₁..Tₙ を適用
        ▼
 親（表示中トップ）空間の N 個の flattened delta
   （同一セルの全インスタンスへファンアウト）
        │
        ▼
 既存の LayoutEditDelta → 全ライブ系 apply（変更なし）
```

このファンアウトが M10 の本体であり、配列（repetition）も「flatten 時に仮想インスタンスへ展開する」だけで全系に波及する。

## フェーズ計画

### M10.0 現状確認（書く前に読む）

- `IRLayoutConverter` で GDS AREF がどの段階で展開されるか特定する（LayoutIR レベルか、converter か）。round-trip（AREF → 編集 → AREF）の現状損失を fixture で記録する。
- 既存の `terminalNetIDs`（インスタンス端子→ネット割付）が flatten でどう使われているかを確認し、EIP の delta 変換と矛盾しないことを固定する。

### M10.1 インスタンス動詞

シェイプ動詞（M4）と同じ規約でインスタンスに動詞を与える:

- `placeInstance(cellID:at:)` / `moveSelectedInstances(by:)` / `rotateSelectedInstances` / `mirrorSelectedInstances` — すべて transform の更新として `commitDelta` 1 回（undo 1 単位）。
- flatten 済みライブ系への delta は「旧 transform での子シェイプ群 removed + 新 transform での added」。**ID は flatten 採番なので multiset オラクルがそのまま効く**（M6 で確立済みの比較規約）。
- `flattenInstance(_:)`: 子シェイプを親へ実体化（ID 新規採番を明示）。逆操作 `makeCellFromSelection(name:)`: 選択シェイプを新セル + インスタンスに置換。両者は往復 fixture（flatten→make-cell→flatten が multiset 一致）で固定する。
- 循環防止: 既存 DFS ガードを `placeInstance` 経路にも適用（自分の祖先セルのインスタンス化を throw）。

### M10.2 edit-in-place（EIP）

```swift
// LayoutEditorViewModel
public func enterInPlaceEdit(instanceID: UUID) throws   // コンテキストスタックに push
public func exitInPlaceEdit()                            // pop
```

- **モデル**: EIP コンテキスト = 表示中トップセル + インスタンスパス（`[instanceID]` の連鎖）。編集対象は末端の子セル。ポインタ座標は逆変換 `T₁⁻¹..Tₙ⁻¹` で子セル空間へ写してから既存の編集動詞に渡す（動詞側は無変更）。
- **delta ファンアウト**: 子セルへの 1 編集を、表示中トップに存在する**その子セルの全インスタンス**分の flattened delta に展開して全ライブ系へ流す。ここが live==batch の主オラクル点:
  - 「EIP で子セルを編集」== 「子セルを直接開いて同じ編集をし、トップへ戻って rebuild」が multiset 一致。
- **描画**: EIP 中はコンテキスト外ジオメトリを減光（plan はそのまま、バッチに `dimmed` フラグを付与）。選択・スナップはコンテキスト内に限定。
- **magnification 注意**: 逆変換は magnification を含む。倍率付きインスタンスの EIP では grid スナップが子セル空間で行われることをテストで固定する（float 往復の丸め — M4 の float-pivot 教訓を適用し、変換往復を 1 回に抑える）。

### M10.3 配列インスタンス `LayoutRepetition`

```swift
public struct LayoutRepetition: Hashable, Sendable, Codable {
    public var columns: Int          // ≥ 1
    public var rows: Int             // ≥ 1
    public var columnStep: LayoutPoint   // GDS AREF は直交だが斜交も表現可能
    public var rowStep: LayoutPoint
}
// LayoutInstance に追加:
//   public var repetition: LayoutRepetition?   （decodeIfPresent で後方互換）
```

- **flatten**: `repetition` を仮想インスタンス (col, row) へ展開して既存経路に流す。展開後の各 shape の出自（instanceID + (col, row)）は flatten 内部でのみ保持（選択ヒットテストが「配列のどの要素か」を返せるように）。
- **編集動詞**: 配列全体の move/rotate は transform 更新。**要素単体の編集は「配列の分解（explode）」を経由**する — 配列のまま 1 要素だけ違う、という状態は作らない（GDS で表現不能な状態をモデルに入れない）。explode は repetition→N 個の個別インスタンス置換で、undo 1 単位。
- **IO round-trip**: GDS AREF ↔ `LayoutRepetition` を `IRLayoutConverter` で無展開対応（reader/writer は対応済みなので converter の写像のみ）。OASIS は既存 8 種 repetition のうち矩形格子型と相互変換、その他の型は**読み込み時に個別展開し、その事実を import 結果に申告**する。
- **オラクル**: `flatten(repetition)` == `flatten(explode した N インスタンス)` が bit-exact（同一 transform 計算経路を通す）。

### M10.4 スケールとベンチマーク

- 配列は「1M シェイプ文書」をモデル上はコンパクトに表現できる（1000×1000 配列 = インスタンス 1 個）。flatten 後の規模は M7 の索引がそのまま支える。
- ベンチ: 100×100 配列 ×100 セル種の文書で、(a) openCell、(b) EIP 進入、(c) EIP 中の 1 編集（ファンアウト 100 インスタンス分）の各時間。EIP 1 編集 ≤ 16ms 目標。
- ファンアウトが大きい編集（多重インスタンス化された下位セルの EIP）はファンアウト数を stats に出す。

## 完了条件（DoD)

| 項目 | 基準 |
|---|---|
| インスタンス動詞 | place/move/rotate/mirror/flatten/make-cell が commitDelta 経由、undo/redo 完全、live==batch |
| EIP 等価 | EIP 編集 == 子セル直接編集 + rebuild（multiset、全ライブ系） |
| 配列等価 | repetition flatten == explode flatten（bit-exact） |
| IO round-trip | GDS AREF が無展開で往復（要素数・ピッチ・transform 保存）。OASIS 非格子型は展開を申告 |
| 後方互換 | repetition なし既存文書の decode/encode が無変更 |
| 性能 | EIP 1 編集（ファンアウト 100）≤ 16ms、配列 explode が undo 1 単位 |

## リスクと対策

| リスク | 対策 |
|---|---|
| EIP の座標往復誤差（特に magnification 付き） | 変換合成を 1 行列に畳んでから 1 回適用。往復 fixture（非自明角度+倍率）で固定 |
| ファンアウト爆発（深い階層 × 多インスタンス） | ファンアウト数を stats で申告し、閾値超過は rebuild へ切替（どちらの経路でも live==batch を保証） |
| 配列の部分編集要求 | explode を明示操作として提供することで「配列のまま例外要素」をモデルから排除 |
| terminalNetIDs と EIP の整合 | M10.0 で flatten のネット割付経路を先に固定し、EIP delta が同じ割付を通ることをテスト化 |
