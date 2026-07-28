import AppKit
import SwiftUI

// 結果ウィンドウの状態管理。
//
// 段階 4 では画像の表示・コピー・保存までを担う。OCR は段階 5 で追加する。
@MainActor
@Observable
final class ResultViewModel {

    /// キャプチャ画像。ウィンドウを閉じたら解放する（非機能要求・メモリ）。
    let image: CGImage

    /// OCR テキスト。編集可能（4.3）。段階 5 で認識結果を流し込む。
    var text: String = ""

    /// OCR 実行中か。プレースホルダ表示に使う（4.3）。
    var isRecognizing: Bool = false

    /// OCR が 1 文字も取れなかったか（4.3）。
    var hasNoText: Bool = false

    /// 認識できた行数。表示の目安に使う。
    var lineCount: Int = 0

    /// コピー・保存の完了フィードバック（CPY-03）。
    var feedback: String?

    /// 画像を等倍（1:1）で表示するか。
    ///
    /// 既定は true。1x ディスプレイでは縮小すると必ずリサンプリングで
    /// ぼやけるため、既定では等倍のまま出してスクロールで見せる。
    /// false にするとウィンドウに合わせて縮小表示する。
    var actualSize: Bool = true

    /// ウィンドウを閉じる要求。
    var requestClose: (() -> Void)?

    /// 現在の認識モード。変更すると即座に再認識する（6.3）。
    var mode: RecognitionMode {
        didSet {
            guard mode != oldValue else { return }
            // 直前に使ったモードを次回の既定として記憶する（6.3）。
            Settings.shared.recognitionMode = mode
            recognize()
        }
    }

    /// 実行中の認識タスク。モード切替時に古い結果で上書きされないよう管理する。
    private var recognitionTask: Task<Void, Never>?

    init(image: CGImage) {
        self.image = image
        self.mode = Settings.shared.recognitionMode
    }

    // MARK: - OCR

    /// OCR を実行する（OCR-01: ボタンを押させず自動実行）。
    ///
    /// 画像プレビューは OCR 完了を待たず先に表示されている（4.3）。
    func recognize() {
        // 前の認識が走っていれば捨てる（モードを素早く切り替えた場合）。
        recognitionTask?.cancel()

        isRecognizing = true
        hasNoText = false

        let image = image
        let mode = mode
        recognitionTask = Task { @MainActor in
            do {
                // await によりメインスレッドを離れて実行される。
                let result = try await TextRecognizer.recognize(image: image, mode: mode)
                // キャンセル済み、または途中でモードが変わっていたら破棄する。
                // 後続の認識が走っているので isRecognizing はそちらに任せる。
                guard !Task.isCancelled, self.mode == mode else { return }
                self.text = result.text
                self.lineCount = result.lineCount
                self.hasNoText = result.lineCount == 0
                self.isRecognizing = false
            } catch {
                // モード切替や終了による中断は異常ではないので何も表示しない。
                //
                // Vision は CancellationError ではなく
                // VisionError.requestCancelled を投げる（実測で確認）ため、
                // 型で分岐せず Task.isCancelled で判定する。
                // コンソールに出る "RecognizeTextRequest was cancelled." は
                // Vision 自身のログで、異常を意味しない。
                guard !Task.isCancelled else { return }
                self.text = ""
                self.lineCount = 0
                self.hasNoText = true
                self.isRecognizing = false
            }
        }
    }

    /// 画像のポイント寸法。1x 環境ではピクセル数と一致する。
    var pixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    // MARK: - コピー

    /// 画像をクリップボードへ（CPY-01、PNG 形式）。
    func copyImage() {
        guard let data = pngData() else {
            showFeedback("画像を変換できませんでした")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // PNG と TIFF の両方を載せると貼り付け先の対応が広い。
        pasteboard.setData(data, forType: .png)
        if let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
        showFeedback("画像をコピーしました")
        closeIfNeeded()
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

    /// デスクトップへ PNG 保存（SAV-01/02/03）。
    func save() {
        guard let data = pngData() else {
            showFeedback("画像を変換できませんでした")
            return
        }
        do {
            let url = try uniqueSaveURL()
            try data.write(to: url)
            showFeedback("保存しました: \(url.lastPathComponent)")
        } catch {
            // SAV-03: 黙って失敗しない。
            presentSaveError(error)
        }
    }

    /// SAV-02: `JPScreenShot_YYYY-MM-DD_HHmmss.png`。既存を上書きしない。
    private func uniqueSaveURL() throws -> URL {
        let directory = Settings.shared.saveDirectory
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = formatter.string(from: Date())
        let base = "JPScreenShot_\(stamp)"

        let fm = FileManager.default
        var candidate = directory.appending(path: "\(base).png")
        // 同一秒に 2 回保存した場合は連番を付ける（SAV-02）。
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "\(base)_\(index).png")
            index += 1
        }
        return candidate
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

    private func pngData() -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private func showFeedback(_ message: String) {
        feedback = message
        // 一定時間で消す。
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if feedback == message { feedback = nil }
        }
    }

    /// CPY-04: コピー後に閉じるかは環境設定（既定は**閉じない**）。
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
