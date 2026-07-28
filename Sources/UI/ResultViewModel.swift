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

    /// コピー・保存の完了フィードバック（CPY-03）。
    var feedback: String?

    /// ウィンドウを閉じる要求。
    var requestClose: (() -> Void)?

    init(image: CGImage) {
        self.image = image
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

    /// CPY-04: コピー後に閉じるかは環境設定（既定は閉じる）。
    private func closeIfNeeded() {
        guard Settings.shared.closeAfterCopy else { return }
        // フィードバックが一瞬見えるように少し待つ。
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            requestClose?()
        }
    }
}
