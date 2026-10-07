# 実装計画-HDR

## 変更履歴

| 日付 | 変更者 | 変更内容 |
| --- | --- | --- |
| 2026-10-07 | Claude | 結果画面の SDR/HDR・保存形式を常にセグメントにし、ウィンドウの最小幅をボタンバー（狭い版・最多ボタン）の実測幅に合わせた。実キャプチャで HEIC/PNG/JPG が揃うことをユーザーが目視確認（差は PNG 比で中央値 1% 前後、圧縮由来）。 |
| 2026-10-07 | Claude | 実機で判明: `.bothSDRAndHDR` は sdrImage にも HDR 画像を返す。SDR 版を `SDRConversion`（1.0 超だけ色相保持で切り詰め。出力色空間のリニア版で行い、失敗は `SDRConversionError` で返す）で自前生成するよう修正。あわせて `ColorGainMap.offset` を 1e-5 → 1/64 に変更（8bit ベースで暗部が 0 に丸められ `measureMaxLog2` が上限 4.0 に張り付いていたため。変更後の実キャプチャで GainMapMax 2.41、読み戻しは元 HDR とほぼ一致）。 |
| 2026-10-07 | Claude | レビュー指摘を修正し（二重実行・上書き防止・HDR 焼き失敗時の SDR 復帰・ゲイン上限 16 倍・未使用コード削除・ボタンバーの狭幅対応・テスト強化）、要求仕様と CLAUDE.md を更新。 |
| 2026-10-07 | Claude | フェーズ4完了（ColorGainMap 移植・3形式の書き出し・保存形式 Picker・HDR コピー）。Metal は `-fcikernel` 系フラグ無しで読める（付けると読めない）。目視は未。 |
| 2026-10-07 | Claude | フェーズ3完了（表示切替・PQ 焼き・Debug のゲインマップ読込）。目視は未。 |
| 2026-10-07 | Claude | フェーズ1・2完了。レビュー指摘（P3 色の HDR 誤判定・メインスレッド処理・色空間タグ欠落ほか9件）を修正。 |
| 2026-10-07 | Claude | 初版作成。撮影・合成・表示・書き出し・仕上げの5フェーズに分けた。 |

## 概要

撮影時に SDR 版と HDR 版を**両方**取っておき、結果画面で SDR/HDR を切り替えられるようにする。表示も保存・コピーも、選んでいるほうに従う。HEIC・PNG・ゲインマップ JPG を結果画面で毎回選んで保存する。

- **対象**: 撮影（`ScreenCaptureService`）・合成（注釈／影／ぼかし）・結果画面の表示と切替・3形式の書き出し・コピー
- **やらないこと**: HDR の OCR（OCR は常に SDR 版）、HDR の動画、Intel Mac での HDR（ScreenCaptureKit が非対応。SDR のみ）、環境設定での既定形式（毎回選ぶ方式に決定）
- **関連**: [要求仕様.md](要求仕様.md)／[実装計画-注釈編集.md](実装計画-注釈編集.md)（別台帳・実装済み）／HDRForge の `Sources/GainForgeCore/ColorGainMap.swift`・`App/Sources/PreviewView.swift`

### 決定事項（2026-10-07）

| 論点 | 決定 |
|---|---|
| HDR の取得 | 常に有効。`SCScreenshotConfiguration.dynamicRange = .bothSDRAndHDR` で 1 回で両方取る |
| 切替 | 撮ってから結果画面で SDR/HDR を選ぶ。表示もそれに追従する |
| 保存形式 | 結果画面で**毎回**選ぶ（HEIC／PNG／ゲインマップ JPG） |
| HDR の PNG | 16bit・ITU-R 2100 PQ の HDR PNG |
| HDR のコピー | ゲインマップ JPEG **だけ**を `public.jpeg` で載せる（HDRForge で形式を同居させて X に貼れなくなった経緯）。SDR のコピーは今どおり PNG＋TIFF |
| ゲインマップ | HEIC は HDRForge の `ColorGainMap`（3ch）を移植。JPEG は CoreImage の `.hdrImage`（1ch） |

## 進捗

**現在**: フェーズ5（次の一手: P5-4 目視確認）

| フェーズ | 状態 | 完了 | 備考 |
| --- | --- | --- | --- |
| 1. 撮影を SDR＋HDR の二系統にする | ✅ 完了 | 6/6 | 目視は P5-4 でまとめて確認 |
| 2. 合成（注釈・影・ぼかし）の HDR 対応 | ✅ 完了 | 4/4 | 178 テスト通過 |
| 3. 結果画面の SDR/HDR 切替と HDR 表示 | ✅ 完了 | 5/5 | 186 テスト通過。目視は未 |
| 4. 3形式の書き出しとコピー | ✅ 完了 | 7/7 | 196 テスト通過。目視は未 |
| 5. 仕上げ（レビュー・ドキュメント・目視） | 🔄 進行中 | 3/4 | 残りは目視（P5-4） |

> 状態: ⬜ 未着手 / 🔄 進行中 / ✅ 完了 / ⏸️ 保留。タスクは `- [ ]` / `- [x]`。
> フェーズ内の全タスクが `- [x]` になったら ✅ にする。備考は1行まで（詳細は各フェーズ本文へ）。

### 更新のきまり

- 更新は実装したターン内で行う（「動いた＝更新済み」と錯覚しない）
- **状態はこの表だけに書く**。フェーズ見出しには書かない
- 変更履歴は**新しい行を上に**足す。1行1文
- 計画とズレたら計画側を直し、変更履歴に残す

---

## フェーズ1: 撮影を SDR＋HDR の二系統にする

**目標**: 撮影結果が SDR 版と HDR 版（HDR 非対応環境では nil）を両方持ち、今までどおりの見た目・解像度で動く。

### タスク

- [x] **P1-1**: 16bit PQ の HDR PNG を ImageIO で書いて読み戻し、色空間が `itur_2100_PQ` のまま残るかをテストで確かめる。駄目なら PNG 方針を見直す（`Tests/HDRPNGSpikeTests.swift`）
- [x] **P1-2**: `CaptureResult` に `hdrImage: CGImage?` を足す。`image` は SDR 版のまま（OCR・既存呼び出しを壊さない）（`Sources/Capture/ScreenCaptureService.swift`）
- [x] **P1-3**: 範囲キャプチャを `SCScreenshotManager.captureScreenshot(contentFilter:configuration:)`＋`SCScreenshotConfiguration`（`dynamicRange = .bothSDRAndHDR`）へ移す。`sourceRect` の整数丸め・`width/height` の等倍指定は維持（`Sources/Capture/ScreenCaptureService.swift`）
- [x] **P1-4**: ウィンドウキャプチャも同様に移す（`ignoreShadows = true`）（`Sources/Capture/ScreenCaptureService.swift`）
- [x] **P1-5**: `ShadowCompositor` を色空間・ビット深度を引数で受ける形にし、HDR 版は拡張 sRGB・16bit float で影を合成する（`Sources/Capture/ShadowCompositor.swift`）
- [x] **P1-6**: HDR 版が実質 SDR か（画素の最大値が 1.0 以下か、表示のヘッドルームが 1.0 か）を判定する純粋関数を用意し、そのときは `hdrImage = nil` にする（`Sources/Capture/HDRAvailability.swift`）

### 完了確認

```bash
npm run test
# 期待: 既存テスト＋HDR PNG 検証・ShadowCompositor・HDRAvailability のテストが全件 pass
npm run build
# 期待: BUILD SUCCEEDED
```

- [ ] 範囲・ウィンドウとも、移行前と同じ鮮明さ・ピクセル寸法で撮れる（目視）

---

## フェーズ2: 合成（注釈・影・ぼかし）の HDR 対応

**目標**: 注釈込みの書き出し画像を、SDR 版と HDR 版のどちらからでも作れる。

### タスク

- [x] **P2-1**: `AnnotationRenderer.renderFlattened` に「出力の色空間とビット深度」を渡せるようにし、HDR 版は拡張 sRGB・16bit float で合成する。注釈の色は SDR の白（1.0）を上限にして光らせない（`Sources/Annotation/AnnotationRenderer.swift`）
- [x] **P2-2**: `RedactionRenderer` のぼかし・モザイクを HDR 版でも 1.0 超を保ったまま処理する（`.RGBA8` → `.RGBAh`）（`Sources/Annotation/RedactionRenderer.swift`）
- [x] **P2-3**: 画面表示側の注釈描画がどちらの版を下敷きにしても同じ位置・見た目になることを確かめる（`Sources/UI/Annotation/AnnotationCanvasView+Drawing.swift`）
- [x] **P2-4**: テスト: HDR 版の合成結果で、注釈の無い画素は 1.0 超を保ち、白い注釈は 1.0 になる（`Tests/AnnotationRendererTests.swift`）

### 完了確認

```bash
npm run test
# 期待: 全件 pass（追加した HDR 合成テストを含む）
```

---

## フェーズ3: 結果画面の SDR/HDR 切替と HDR 表示

**目標**: 結果画面で SDR/HDR を切り替えると、表示が実際に HDR（EDR）／SDR に変わる。

### タスク

- [x] **P3-1**: `ResultViewModel` に表示中のダイナミックレンジ（`.sdr` / `.hdr`）を持たせる。`hdrImage` があれば既定は `.hdr`、無ければ `.sdr` 固定（`Sources/UI/ResultViewModel.swift`）
- [x] **P3-2**: `BaseImageView` の `imageLayer` に `preferredDynamicRange`（`.high`/`.standard`）と `toneMapMode = .never` を設定し、HDR 版は 16bit・`calculateHDRStats: true` で `contentHeadroom` 付きの CGImage を渡す（HDRForge `PreviewView.applyDynamicRange` / `cgImage(from:rect:)` の知見）（`Sources/UI/Annotation/AnnotationCanvasParts.swift`）
- [x] **P3-3**: 結果画面に SDR/HDR の切替（セグメント）を置く。HDR 版が無いときは無効化し、理由をツールチップで出す（`Sources/UI/ResultView.swift`）
- [x] **P3-4**: Debug の `-JPSOpenImage` がゲインマップ付き HEIC/JPEG を読めるようにし、SDR 版とHDR 版（`CIImage` の `.expandToHDR`）を両方渡す。画面収録の権限なしで HDR 表示を確かめるため（`Sources/App/AppCoordinator.swift`）
- [x] **P3-5**: 切替時に注釈・選択状態・表示倍率が保たれる（`Sources/UI/Annotation/AnnotationCanvasView.swift`）

### 完了確認

```bash
npm run test && npm run build
# 期待: 全件 pass・BUILD SUCCEEDED
```

- [ ] HDR 対応ディスプレイで、HDR を選ぶと明部が光り、SDR を選ぶと光らない（目視）
- [ ] 切り替えても注釈が消えず、位置もずれない（目視）

---

## フェーズ4: 3形式の書き出しとコピー

**目標**: 結果画面で選んだ形式・ダイナミックレンジで保存でき、HDR のコピーはゲインマップ JPEG になる。

### タスク

- [x] **P4-1**: HDRForge の `ColorGainMap.swift` と `Kernels/ColorGainMap.metal`（使うカーネル: `gainforgeTemplate` / `gainforgeLogGain` / `gainforgeGainMap`）を移植し、`MetalKernelLibrary` を `Bundle.main` 読みにする。色温度調整（`HighlightWarmth` / `HighlightTint`）は持ち込まない（`Sources/Export/ColorGainMap.swift`・`Sources/Export/Kernels/`）
- [x] **P4-2**: `project.yml` で `.metal` を `default.metallib` にビルドする。カーネルは `[[stitchable]]` なのでフラグ（`-fcikernel` 系）は不要（付けると読めない）。読み込み失敗は標準エラーに理由を出す（`project.yml`）
- [x] **P4-3**: 書き出し器: SDR は HEIC（8bit）／PNG（8bit）／JPEG、HDR は HEIC（10bit・3ch ゲインマップ）／PNG（16bit PQ）／JPEG（1ch ゲインマップ）（`Sources/Export/ImageExporter.swift`）
- [x] **P4-4**: テスト: HDR の HEIC がカラーゲインマップを持つ（`isColorGainMap`）・JPEG がゲインマップを持つ・PNG が PQ 色空間で 16bit（`Tests/ImageExporterTests.swift`）
- [x] **P4-5**: 結果画面に保存形式の選択（HEIC／PNG／JPG）を置き、保存は選んだ形式と表示中のダイナミックレンジで行う。拡張子も合わせる（SAV-02 の連番規則は維持）（`Sources/UI/ResultView.swift`・`Sources/UI/ResultViewModel.swift`）
- [x] **P4-6**: コピー: HDR 表示中はゲインマップ JPEG だけを `public.jpeg` で載せる。SDR は今どおり PNG＋TIFF（`Sources/UI/ResultViewModel.swift`）
- [x] **P4-7**: 書き出し失敗（カーネル読み込み失敗・ゲインマップ検算失敗）を黙って SDR に落とさず、フィードバックかアラートで伝える（`Sources/UI/ResultViewModel.swift`）

### 完了確認

```bash
npm run test && npm run build
# 期待: 全件 pass・BUILD SUCCEEDED
```

- [x] 保存した HDR の HEIC・JPG をプレビュー／写真アプリで開くと HDR で表示される（目視）
- [x] HDR の PNG が、HDR 対応アプリで HDR として表示される（目視）
- [ ] HDR でコピーした画像を X とプレビュー（クリップボードから新規作成）に貼れる（目視）

---

## フェーズ5: 仕上げ（レビュー・ドキュメント・目視）

**目標**: レビュー指摘が片付き、仕様書と CLAUDE.md が実装に追いついている。

### タスク

- [x] **P5-1**: 変更全体を code-reviewer でレビューし、妥当な指摘を修正する
- [x] **P5-2**: 要求仕様に HDR の項（撮影・切替・保存形式・コピー）を足す（`Docs/要求仕様.md`）
- [x] **P5-3**: CLAUDE.md の「コード上の注意」に HDR の落とし穴（表示は PQ でなく拡張 sRGB でも `toneMapMode` が要るか等、実装で判明したこと）を足す（`CLAUDE.md`）
- [ ] **P5-4**: フェーズ1・3・4 の目視項目をまとめて確認する

### 完了確認

```bash
npm run test && npm run build
# 期待: 全件 pass・BUILD SUCCEEDED
```

- [ ] HDR 表示に切り替えたとき、SDR 部分（白・灰色）の明るさが SDR 表示と変わらない（輝度スライダー最小・中・最大で）（目視）
- [ ] 全目視項目を確認済み（目視）

---

## 全体の完了基準

- [ ] 撮影後に SDR/HDR を切り替えられ、表示・保存・コピーが選んだほうに従う
- [ ] HEIC／PNG／ゲインマップ JPG の3形式で、SDR・HDR とも保存できる
- [ ] HDR 非対応環境では、今までどおり SDR だけで動く
- [ ] `npm run test` が全件 pass、`npm run build` が成功する

## 注意点

- **`SCScreenshotConfiguration` には `captureResolution` と `scalesToFit` が無い。** `width/height` 指定で等倍になるかは P1-3 で実測する（`sourceRect` の整数丸めと同じく、ぼやけは目視でしか分からない）
- **`hdrImage` は拡張 sRGB、`sdrImage` はディスプレイの色空間**（SDK ヘッダの記述）。ゲインマップを作るときは両者を同じ作業空間（拡張リニア）に入れてから差を取る
- **HDR 表示は「相乗り」に注意**（HDRForge 知見-GUI §3）。他アプリが EDR を有効にしていると、設定が足りなくても光って見える。目視確認は他の HDR アプリを閉じて行う
- **ColorGainMap のメタデータはダミーを CoreImage に書かせて借りている**（`template`）。カーネルが読めないと `nil` になり 3ch が作れない。その場合は 1ch（`writeHEIF10Representation` の `.hdrImage`）へ落とすか失敗にするかを P4-7 で決める。**決定: 失敗にする**（`ExportError.kernelUnavailable`。保存はアラート、コピーはフィードバックで伝える）
- **`calculateHDRStats: true` を付けないと `contentHeadroom` が付かず、`.high` を要求しても SDR 表示のまま**（HDRForge `PreviewView.cgImage(from:rect:)`）
