import AppKit
import ScreenCaptureKit

// ScreenCaptureKit による範囲キャプチャ（CAP-02 / CAP-03 / CAP-04）。
//
// 実装計画 1.2 のとおり、必ずフィルタ方式を使う。
// SCScreenshotManager.captureImage(in:) は簡潔だがコンテンツフィルタを
// 受け取れず、暗転オーバーレイが写り込むため CAP-04 を満たせない。
enum CaptureError: LocalizedError {
    case noDisplayFound
    case captureFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            "キャプチャ対象のディスプレイを特定できませんでした。"
        case .captureFailed(let error):
            "キャプチャに失敗しました: \(error.localizedDescription)"
        }
    }
}

@MainActor
enum ScreenCaptureService {

    /// 共有可能コンテンツを取得する。
    ///
    /// 実装計画 6.4: この呼び出しは時間がかかるため、範囲選択の開始と同時に
    /// 先読みしておき、ユーザーがドラッグしている間に完了させる。
    static func fetchShareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
    }

    /// 指定した範囲をキャプチャする。
    /// - Parameters:
    ///   - appKitRect: AppKit グローバル座標（左下原点）の矩形。
    ///   - content: 先読みしておいた共有可能コンテンツ。省略時はここで取得する。
    /// - Returns: Retina 解像度を維持した CGImage（CAP-02）。
    static func capture(
        appKitRect: CGRect,
        content preloaded: SCShareableContent? = nil
    ) async throws -> CGImage {
        guard let screen = ScreenGeometry.screen(containing: appKitRect),
              let displayID = ScreenGeometry.displayID(of: screen)
        else {
            throw CaptureError.noDisplayFound
        }

        let content: SCShareableContent
        if let preloaded {
            content = preloaded
        } else {
            content = try await fetchShareableContent()
        }

        guard let display = content.displays.first(where: { $0.displayID == displayID })
        else {
            throw CaptureError.noDisplayFound
        }

        // CAP-04: 自プロセスのウィンドウを除外する。
        //
        // 主たる対策は SelectionCoordinator が「キャプチャ前にオーバーレイを
        // 閉じる」こと（実装計画 6.2）。この除外指定は二重の保険であり、
        // content を選択中に先読みした場合はオーバーレイがまだ開いているため
        // 実際に効く。閉じた後に取得した content では ownWindows は空になる。
        let myPID = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter {
            $0.owningApplication?.processID == myPID
        }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

        // sourceRect は CoreGraphics 座標（左上原点）のポイントで指定する。
        // ここが座標系変換の要（実装計画 6.1）。
        let cgRect = ScreenGeometry.convertToCoreGraphics(appKitRect)
        // ディスプレイ内のローカル座標に直す。
        let displayBounds = CGDisplayBounds(displayID)
        let localRect = CGRect(
            x: cgRect.origin.x - displayBounds.origin.x,
            y: cgRect.origin.y - displayBounds.origin.y,
            width: cgRect.width,
            height: cgRect.height
        )

        // ★ピクセル境界に整列させる（ぼやけ防止）
        //
        // sourceRect に小数が入ると ScreenCaptureKit がサブピクセル位置から
        // 取得するため補間が入り、目に見えてぼやける。
        // 実測: 整数の rect は鮮明度 7.629、0.5 ずれただけで 5.132 に低下した。
        //
        // ドラッグの座標は NSEvent.mouseLocation 由来で小数を含むため、
        // 何も対策しないとほぼ毎回この劣化を踏む。整数に丸めて
        // 画面のピクセルと 1:1 で対応させる。
        let sourceRect = CGRect(
            x: localRect.origin.x.rounded(.down),
            y: localRect.origin.y.rounded(.down),
            width: localRect.width.rounded(),
            height: localRect.height.rounded()
        )

        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        // CAP-02: ポイントの backingScale 倍のピクセル数を要求して
        // Retina 解像度のまま取得する（ダウンスケールさせない）。
        let scale = screen.backingScaleFactor
        config.width = Int((sourceRect.width * scale).rounded())
        config.height = Int((sourceRect.height * scale).rounded())
        config.captureResolution = .best
        config.showsCursor = false
        config.scalesToFit = false

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            throw CaptureError.captureFailed(error)
        }
    }
}
