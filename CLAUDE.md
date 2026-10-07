# CLAUDE.md

JPScreenShot で作業する際の指針。詳細な仕様・設計は [Docs/要求仕様.md](Docs/要求仕様.md) と [Docs/実装計画.md](Docs/実装計画.md) を参照。

## このアプリ

macOS のメニューバーから範囲キャプチャし、**画像と OCR テキストの両方を同時に得る**アプリ。SwiftUI（結果ウィンドウ）+ AppKit（`NSStatusItem`・オーバーレイ）、キャプチャは ScreenCaptureKit、OCR は Vision の `RecognizeTextRequest`。macOS 26 以降・Swift 6 の厳格並行モード。

## ビルド

**`.xcodeproj` は生成物で版管理していない。** `project.yml` が真実のソース。

```sh
xcodegen generate                    # まずこれ（.xcodeproj が無ければビルドできない）
xcodebuild -project JPScreenShot.xcodeproj -scheme JPScreenShot \
  -configuration Debug -derivedDataPath dd -clonedSourcePackagesDirPath dd/SourcePackages build
xcodebuild ... test                  # テストは Tests/（純粋関数のみ・画面権限不要）
```

`-clonedSourcePackagesDirPath` は Sparkle（SwiftPM 依存）の取得先を `dd/` に閉じ込めるため。

同じことを [package.json](package.json) の npm スクリプトからも実行できる（VSCode の NPM SCRIPTS パネル用。npm 依存はない）。

```sh
npm run build     # generate + Debug ビルド
npm run test      # generate + テスト
npm run release   # リリース発火（Tools/release.sh）
```

### Info.plist も生成物だが版管理している

Sparkle の `SUFeedURL` / `SUPublicEDKey` は `INFOPLIST_KEY_*` では注入できないため、実 `Info.plist` を XcodeGen に生成させている。**`JPScreenShot-Info.plist` を直接編集しても `xcodegen generate` で消える。** 設定変更は `project.yml` 側で行い、再生成して両方コミットする。

## 画面収録の権限（最大の落とし穴）

TCC の許可は**署名の同一性（Bundle ID + Team ID）に紐づく**。そのため:

- `project.yml` で開発用の署名 ID を固定している（`CODE_SIGN_IDENTITY: "Apple Development"` / `DEVELOPMENT_TEAM: L897K2C26B`）。ad-hoc 署名だと `CDHash` がビルドごとに変わり許可が毎回リセットされる
- 開発版（Apple Development）と配布版（Developer ID）は別署名なので、**許可は引き継がれない**
- `tccutil reset` は安易に打たない。要求済みの記録まで消えると `CGRequestScreenCaptureAccess()` がダイアログを出さずに false を返し、システム設定の一覧からも消えて手動追加が必要になる

「許可したのに撮れない」ときは**実際に動いているバイナリのパスを確認する**:

```sh
pgrep -lf JPScreenShot
```

`dd/`（CLI ビルド）と `~/Library/Developer/Xcode/DerivedData/JPScreenShot-*`（Xcode ビルド）に別の実体ができるため、意図しないコピーが動いていることがある。

## リリース・CI

タグ `v*` の push で [.github/workflows/release.yml](.github/workflows/release.yml) が署名・公証・配布・appcast 更新まで自動実行する。手順とセットアップ状況は **[Docs/リリース手順.md](Docs/リリース手順.md)** に集約。

```sh
Tools/release.sh 0.1.0        # バージョン更新 → コミット → タグ → push
```

署名・公証に使う証明書と API キーの実物は `~/Dropbox/アプリ/JPScreenShot/` にある（リポジトリには含めない）。**内訳・Key ID・有効期限・GitHub Secrets の登録状況はすべて [Docs/リリース手順.md](Docs/リリース手順.md) に書いてある**ので、そちらを見ること。

| 項目 | 値 |
|---|---|
| Team ID | `L897K2C26B` |
| Bundle ID | `com.junpeiwada.JPScreenShot` |

## コード上の注意

- **`SCShareableContent` は非 `Sendable`。** `Task` の結果型にするとアクター境界を越えられない。MainActor 隔離のプロパティに格納し、`Task` は `Void` を返す形にする（実装計画 6.5）
- **オーバーレイの写り込み防止に `SCContentFilter` が必須。** `captureImage(in:)` はフィルタを受け取れないので使えない（実装計画 1.2）
- **`sourceRect` は整数に丸める。** 小数のままだとキャプチャがぼやける
- **注釈の座標は画像のポイント座標**（`CaptureResult.pointSize` の空間、左上原点・y 下向き）。ピクセルでも画面座標でもない。画面では表示倍率（表示幅 ÷ pointSize）を掛け、書き出しでは `capture.scale` を掛ける
- **画面表示と書き出しは `AnnotationRenderer` に一本化する。** 描画を別実装にすると画面とコピー・保存の見た目がずれる。重なり順は配列ではなく**層**（元画像 → ぼかし・モザイク → 図形・テキスト）で固定
- **⌘Z は SwiftUI の `.keyboardShortcut` にしない。** メインメニューの `undo:` / `redo:` を First Responder（キャンバスか OCR テキスト欄）に届けて分ける。`.keyboardShortcut("z")` だと OCR 欄の取り消しを奪う
- **`Esc` は「閉じる」ボタンの `.cancelAction` と取り合う。** テキスト編集中・キャンバスで選択ありのときは外す（`AnnotationKeyboard.closeButtonOwnsEscape`）
- **画面収録の権限なしで結果ウィンドウを見る**: Debug ビルドに `-JPSOpenImage <PNG のパス>`（任意で `-JPSOpenImageScale 2`）を渡す
- **HDR 表示は PQ・RGBA16・`calculateHDRStats: true` で焼く（`HDRDisplayBaker`）。** レイヤーには `preferredDynamicRange = .high` と `toneMapMode = .never` を付ける。拡張 sRGB のままだと他アプリの EDR に相乗りして光って見えるだけで、窓構成が変わると SDR に落ちる
- **HDR 版かどうかは輝度で判定する（`HDRAvailability`）。** 成分の最大値で見ると、Display P3 の鮮やかな色（拡張 sRGB で 1 超になる）を HDR と誤判定する
- **ゲインマップ HEIC は `ColorGainMap`（Metal カーネル）で 3ch を自作する。** カーネルは `[[stitchable]]` なので `-fcikernel` 系のフラグは不要（付けると読めない）。ゲイン上限は画像ごとに実測し、安全上限は 16 倍。**offset は 1/64**（ベースが 8bit のため。1e-5 だと暗部が 0 に丸められ `measureMaxLog2` が上限 4.0 に張り付く）。CI には Metal Toolchain の導入が要る（release.yml）
- **`.bothSDRAndHDR` は SDR/HDR 両方に同じ HDR 画像を返す（実測 2026-10-07）。** SDR 版は `SDRConversion` で自前生成する（1.0 超だけ色相保持で切り詰め。`CIToneMapHeadroom` は UI の白を落とすので使わない）。切り詰めは出力色空間（ディスプレイ ICC）の拡張リニア版で行い、線形化できない空間では作業空間（リニア P3）に落とす。`makeSDR` は失敗理由を `SDRConversionError`（kernelUnavailable / renderFailed）で投げ、撮影エラーとして利用者へ伝える（単純クランプに黙って落とさない）。ディスプレイ色空間は `supportsOutput && model == .rgb` でなければ Display P3 へフォールバック
- **HDR のコピーはゲインマップ JPEG だけ。** 形式を同居させると X に貼れない。書き出し失敗は SDR に黙って落とさず、ユーザーに伝える
