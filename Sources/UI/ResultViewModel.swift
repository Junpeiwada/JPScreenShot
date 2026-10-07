import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 結果ウィンドウの状態管理。
//
// 段階 4 では画像の表示・コピー・保存までを担う。OCR は段階 5 で追加する。
@MainActor
@Observable
final class ResultViewModel {

    /// キャプチャ結果（画像とその倍率）。
    /// ウィンドウを閉じたら解放する（非機能要求・メモリ）。
    ///
    /// 寸法の計算は CaptureResult 側に一本化し、ここでは持ち回すだけにする。
    /// 同じ計算を両方に書くと、ゼロ除算ガードの有無のような差が生まれる。
    private let capture: CaptureResult

    /// キャプチャ画像。
    var image: CGImage { capture.image }

    /// 画像の倍率（1 ポイントあたりのピクセル数。Retina なら 2.0）。
    ///
    /// 表示のときに `Image(decorative:scale:)` へ渡す。ここを 1.0 に
    /// 決め打ちすると 2x で撮った画像が 2 倍の大きさで表示されてしまう。
    var imageScale: CGFloat { capture.scale }

    /// 注釈編集の状態（注釈・選択・取り消し・現在のツール）。
    /// ウィンドウを閉じるときに `tearDown()` で解放する。
    let editor: AnnotationEditor

    /// 表示中のダイナミックレンジ。真実のソースは `editor.dynamicRange`（下敷き画像・加工
    /// キャッシュ・キャンバスの表示がすべてそれに従う）。HDR 版が無いと `.hdr` にはできない。
    var dynamicRange: ImageDynamicRange {
        get { editor.dynamicRange }
        set { editor.dynamicRange = newValue }
    }

    /// HDR 版があり、切替が有効か。
    var hasHDR: Bool { editor.hasHDR }

    /// OCR テキスト。編集可能（4.3）。段階 5 で認識結果を流し込む。
    var text: String = ""

    /// OCR を一度でも始めたか（OCR-01）。
    ///
    /// OCR は「テキストを認識」を押したときだけ走らせる。スクリーンショット
    /// として使うことが多く、使わない認識結果のためにテキスト欄が画像の
    /// 場所を取るのは邪魔なため。false の間はテキスト欄を縮めて表示する。
    var hasStartedRecognition: Bool = false

    /// OCR 実行中か。プレースホルダ表示に使う（4.3）。
    var isRecognizing: Bool = false

    /// OCR が 1 文字も取れなかったか（4.3）。
    var hasNoText: Bool = false

    /// 認識できた行数。表示の目安に使う。
    var lineCount: Int = 0

    /// コピー・保存の完了フィードバック（CPY-03）。
    var feedback: String?

    /// 画像を等倍（画面と同じ大きさ）で表示するか。
    ///
    /// ここでいう等倍は「撮った範囲が画面上で占めていたのと同じ大きさ」で
    /// あり、ピクセル 1:1 ではない。Retina では画像のピクセル数は画面の
    /// 2 倍あるので、ピクセル 1:1 で出すと 2 倍に引き伸ばされて見える。
    ///
    /// 既定は true。縮小するとリサンプリングでぼやけるため、既定では
    /// 等倍のまま出して収まらない分はスクロールで見せる。
    /// false にするとウィンドウに合わせて縮小表示する。
    ///
    /// 選択は次回以降の既定として記憶する。
    ///
    /// 値を複製せず Settings を直接読み書きする。設定にも同じ項目が
    /// あるため、複製すると「設定で切り替えたのに開いている結果
    /// ウィンドウが変わらない」というずれが起きる。Settings は
    /// @Observable なので、どちらから変えても両方の表示が追従する。
    var actualSize: Bool {
        get { Settings.shared.actualSize }
        set { Settings.shared.actualSize = newValue }
    }

    /// ウィンドウを閉じる要求。
    var requestClose: (() -> Void)?

    /// 結果ウィンドウから新しいキャプチャを始める要求（CAP-09）。
    var requestNewCapture: (() -> Void)?

    /// キャンバス欄（スクロール領域）の実寸が変わったときの通知。ウィンドウが開いた直後に
    /// 1 回だけ初期サイズの不足を補正するために使う（ResultWindow）。
    var onCanvasViewportChange: ((CGSize) -> Void)?

    /// テキスト欄を開いたときの通知。ウィンドウを伸ばして画像の場所を確保する。
    var onTextPaneOpened: (() -> Void)?

    /// 現在の認識モード。変更すると即座に再認識する（6.3）。
    var mode: RecognitionMode {
        didSet {
            guard mode != oldValue else { return }
            // 直前に使ったモードを次回の既定として記憶する（6.3）。
            Settings.shared.recognitionMode = mode
            // 認識を始める前はモードを選んでおくだけにする（OCR-01）。
            guard hasStartedRecognition else { return }
            recognize()
        }
    }

    /// 実行中の認識タスク。モード切替時に古い結果で上書きされないよう管理する。
    private var recognitionTask: Task<Void, Never>?

    /// 認識の世代番号。
    ///
    /// 「最後に始めた認識だけが結果を書く」ことを保証する。モードの比較で
    /// 判定すると、同じモードで再認識した場合に古い結果を弾けない。
    private var generation = 0

    init(capture: CaptureResult) {
        self.capture = capture
        self.editor = AnnotationEditor(
            base: capture.image, scale: capture.scale, hdrBase: capture.hdrImage)
        self.mode = Settings.shared.recognitionMode
        // HDR 版があれば既定は HDR（撮ったままの明るさで見せる）。無ければ .sdr 固定。
        if editor.hasHDR { editor.dynamicRange = .hdr }
    }

    // MARK: - OCR

    /// 「テキストを認識」ボタン（OCR-01）。テキスト欄を開いて認識を始める。
    func startRecognition() {
        guard !hasStartedRecognition else { return }
        // 入力途中の注釈テキストは先に確定する（キャンバスは作り直さないが、保険）。
        editor.finishTextEditing()
        hasStartedRecognition = true
        onTextPaneOpened?()
        recognize()
    }

    /// OCR を実行する。
    ///
    /// 画像プレビューは OCR 完了を待たず先に表示されている（4.3）。
    private func recognize() {
        // 前の認識が走っていれば捨てる（モードを素早く切り替えた場合）。
        recognitionTask?.cancel()
        generation += 1
        let myGeneration = generation

        isRecognizing = true
        hasNoText = false

        let image = image
        let mode = mode
        recognitionTask = Task { @MainActor in
            do {
                // await によりメインスレッドを離れて実行される。
                let result = try await TextRecognizer.recognize(image: image, mode: mode)
                // 自分が最新の認識でなければ結果を捨てる。
                // 後続が走っているので isRecognizing はそちらに任せる。
                guard myGeneration == self.generation else { return }
                self.text = result.text
                self.lineCount = result.lineCount
                self.hasNoText = result.lineCount == 0
                self.isRecognizing = false
            } catch {
                // モード切替や終了による中断は異常ではないので何も表示しない。
                //
                // Vision は CancellationError ではなく
                // VisionError.requestCancelled を投げる（実測で確認）ため、
                // 型では分岐しない。世代番号が古ければ中断されたとみなす。
                // コンソールに出る "RecognizeTextRequest was cancelled." は
                // Vision 自身のログで、異常を意味しない。
                guard myGeneration == self.generation, !Task.isCancelled else { return }
                self.text = ""
                self.lineCount = 0
                self.hasNoText = true
                self.isRecognizing = false
            }
        }
    }

    /// 画像のピクセル寸法。保存・コピーされる実データのサイズ。
    ///
    /// 寸法ラベルにはこちらを出す（PNG を開いたときの数字と一致させるため）。
    /// レイアウト計算に使ってはいけない。ポイントとは倍率の分ずれる。
    var pixelSize: CGSize { capture.pixelSize }

    /// 画面上で見えていた大きさ（ポイント）。
    ///
    /// ウィンドウの寸法計算や「等倍」表示はすべてこちらを基準にする。
    /// これにより、撮った範囲が画面で占めていたのと同じ大きさで表示される。
    var pointSize: CGSize { capture.pointSize }

    // MARK: - コピー

    /// 画像をクリップボードへ（CPY-01）。
    ///
    /// - SDR 表示中: 従来どおり PNG と TIFF の両方（貼り付け先の対応が広い）。
    /// - HDR 表示中: ゲインマップ付き JPEG **だけ**を `public.jpeg` で載せる。ゲインマップ付き JPEG は
    ///   それ自体が普通の JPEG なので、ゲインマップを解さないアプリには SDR として、解するアプリには
    ///   HDR として貼られる。形式を同居させると X に貼れなかった（HDRForge 知見-GUI「画像をコピー」）。
    func copyImage() {
        guard beginExporting() else { return }
        let range = dynamicRange
        Task { @MainActor in
            defer { isExporting = false }
            do {
                guard let (sdr, hdr) = flattenedImages(for: range) else {
                    showFeedback("画像を変換できませんでした")
                    return
                }
                let pasteboard = NSPasteboard.general
                switch range {
                case .hdr:
                    let jpeg = try await Self.encode(format: .jpeg, range: .hdr, sdr: sdr, hdr: hdr)
                    pasteboard.clearContents()
                    pasteboard.setData(jpeg, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
                case .sdr:
                    let (png, tiff) = try await Self.encodePNGAndTIFF(sdr)
                    pasteboard.clearContents()
                    pasteboard.setData(png, forType: .png)
                    if let tiff { pasteboard.setData(tiff, forType: .tiff) }
                }
                showFeedback(range == .hdr ? "HDR 画像をコピーしました" : "画像をコピーしました")
                closeIfNeeded()
            } catch {
                // 黙って SDR に落とさない（P4-7）。
                showFeedback("コピーできませんでした: \(error.localizedDescription)")
            }
        }
    }

    /// テキストをクリップボードへ（CPY-02、編集後の内容）。
    func copyText() {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showFeedback("テキストをコピーしました")
        closeIfNeeded()
    }

    var canCopyText: Bool {
        !isRecognizing && !hasNoText && !text.isEmpty
    }

    // MARK: - 保存

    /// 選んだ保存形式。直前の選択を覚える（Settings.exportFormat のコメント参照）。
    /// 複製せず Settings を直接読み書きする（actualSize と同じ理由）。
    var exportFormat: ImageExporter.Format {
        get { Settings.shared.exportFormat }
        set { Settings.shared.exportFormat = newValue }
    }

    /// 書き出し中か。二重実行を防ぎ、ボタンを無効にするのに使う。
    private(set) var isExporting = false

    /// 保存先へ、選んだ形式 × 表示中のダイナミックレンジで保存する（SAV-01/02/03）。
    ///
    /// 重い処理（10bit HEIC のエンコード・ゲインマップ生成は 4K 級で数百 ms〜数秒）はメインを止めない
    /// よう `Task.detached` に出す。注釈の焼き込み（CGContext 描画・MainActor 隔離）だけはメインで行う。
    func save() {
        guard beginExporting() else { return }
        let format = exportFormat
        let range = dynamicRange
        // ファイル名の時刻は押した瞬間のもの。エンコード（数秒かかり得る）の後に取ると、
        // 押した時刻とずれ、連続して押した保存の順序も入れ替わり得る。
        let savedAt = Date()
        Task { @MainActor in
            defer { isExporting = false }
            guard let (sdr, hdr) = flattenedImages(for: range) else {
                showFeedback("画像を変換できませんでした")
                return
            }
            do {
                let data = try await Self.encode(format: format, range: range, sdr: sdr, hdr: hdr)
                let url = try writeUniquely(data, fileExtension: format.fileExtension, at: savedAt)
                showFeedback("保存しました: \(url.lastPathComponent)")
            } catch {
                // SAV-03: 黙って失敗しない。書き出しの失敗（カーネル・ゲインマップ検算など）も
                // 同じ経路で伝え、SDR へ黙って落とさない（P4-7）。
                presentSaveError(error)
            }
        }
    }

    /// 書き出しの開始を宣言する。実行中なら false を返し、押したのに何も起きない状態を避けるため
    /// 理由を伝える。
    ///
    /// フラグは Task を作る**前**に同期で立てる。Task の中で立てると、Task が走り出すまでの間に
    /// もう一度ボタンが押されて二重に走る（ショートカットの連打）。解除は呼び出し側の Task で `defer`。
    private func beginExporting() -> Bool {
        guard !isExporting else {
            showFeedback("書き出し中です")
            return false
        }
        isExporting = true
        return true
    }

    /// SAV-02: `JPScreenShot_YYYY-MM-DD_HHmmss.<拡張子>`。既存を上書きしない。
    ///
    /// 存在確認してから書くと、確認と書き込みの間に同名ファイルができたとき上書きする。
    /// `.withoutOverwriting` で「無いときだけ作る」を書き込み側に任せ、既存で失敗したら
    /// 連番を進めて再試行する。
    private func writeUniquely(_ data: Data, fileExtension: String, at date: Date) throws -> URL {
        let directory = Settings.shared.saveDirectory

        // 保存先が消えている場合（設定で選んだフォルダを後から削除した、
        // 外部ボリュームが外れた等）は、書き込み失敗より前に明確に伝える。
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw CocoaError.error(.fileNoSuchFile, url: directory)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let base = "JPScreenShot_\(formatter.string(from: date))"

        // 同一秒に 2 回保存した場合は連番を付ける（SAV-02）。拡張子ごとに数える。
        var index = 1
        while true {
            let name = index == 1 ? "\(base).\(fileExtension)" : "\(base)_\(index).\(fileExtension)"
            let candidate = directory.appending(path: name)
            do {
                try data.write(to: candidate, options: .withoutOverwriting)
                return candidate
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                index += 1
                // 無限ループ防止（現実には起きない上限）。
                if index > 10_000 { throw error }
            }
        }
    }

    private func presentSaveError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "保存できませんでした"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    // MARK: - 補助

    /// ウィンドウを閉じるときに呼ぶ。走っている認識を止める。
    func cancelRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    /// コピー・保存する画像。注釈を焼き込んだもの（0 件なら元画像そのまま）。
    /// 表示中のダイナミックレンジが HDR なら HDR 版（ゲインマップの高い側）も作る。
    ///
    /// OCR は `image`（元画像）のまま。注釈の線や文字を認識結果に混ぜないため。
    /// 注釈は SDR の白で描かれるので、SDR 版と HDR 版の差（＝ゲイン）は元画像の明部だけに出る。
    private func flattenedImages(for range: ImageDynamicRange) -> (sdr: CGImage, hdr: CGImage?)? {
        // 入力途中のテキストも含めて書き出す（ボタンはフォーカスを奪わないので、
        // ここで明示的に確定する）。
        editor.finishTextEditing()
        let annotations = editor.document.annotations
        guard let sdr = AnnotationRenderer.renderFlattened(
            base: image, scale: capture.scale, annotations: annotations)
        else { return nil }
        guard range == .hdr else { return (sdr, nil) }
        guard let hdrBase = editor.hdrImage,
              let hdr = AnnotationRenderer.renderFlattened(
                  base: hdrBase, scale: capture.scale, annotations: annotations)
        else { return nil }
        return (sdr, hdr)
    }

    /// 書き出しをメインスレッドの外で行う（ImageExporter は状態を持たず、CGImage は Sendable）。
    private nonisolated static func encode(
        format: ImageExporter.Format, range: ImageDynamicRange, sdr: CGImage, hdr: CGImage?
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try ImageExporter.export(format: format, dynamicRange: range, sdr: sdr, hdr: hdr)
        }.value
    }

    /// SDR コピー用。PNG と TIFF を外で作る。
    private nonisolated static func encodePNGAndTIFF(_ image: CGImage) async throws -> (Data, Data?) {
        try await Task.detached(priority: .userInitiated) {
            let png = try ImageExporter.export(format: .png, dynamicRange: .sdr, sdr: image, hdr: nil)
            return (png, NSBitmapImageRep(cgImage: image).tiffRepresentation)
        }.value
    }

    private func showFeedback(_ message: String) {
        feedback = message
        // 一定時間で消す。
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if feedback == message { feedback = nil }
        }
    }

    /// CPY-04: コピー後に閉じるかは設定（既定は**閉じない**）。
    ///
    /// 閉じるのはユーザーの操作に任せる方針。画像とテキストの両方を
    /// コピーしたい、コピー後に内容を見返したい、といった使い方が
    /// 勝手に閉じられると成立しないため。
    private func closeIfNeeded() {
        guard Settings.shared.closeAfterCopy else { return }
        // フィードバックが一瞬見えるように少し待つ。
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            requestClose?()
        }
    }
}
