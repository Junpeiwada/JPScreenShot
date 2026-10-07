import AppKit
import ScreenCaptureKit

// ScreenCaptureKit による範囲キャプチャ（CAP-02 / CAP-03 / CAP-04）。
//
// 実装計画 1.2 のとおり、必ずフィルタ方式を使う。
// SCScreenshotManager.captureImage(in:) は簡潔だがコンテンツフィルタを
// 受け取れず、暗転オーバーレイが写り込むため CAP-04 を満たせない。
//
// 撮影は macOS 26 の SCScreenshotManager.captureScreenshot(contentFilter:configuration:)
// を使い、`.bothSDRAndHDR` で 1 回だけ撮る（実装計画-HDR）。旧 captureImage は SDR しか
// 返せない。
//
// ★実測（2026-10-07）: `.bothSDRAndHDR` は sdrImage にも hdrImage にも**同じ HDR 画像**
// （16bit float・拡張 sRGB）を返す（displayIntent .local / .canonical どちらでも）。
// 「sdrImage はディスプレイの色空間の SDR」ではない。`.sdr` 単独は色空間 nil、`.hdr` 単独は
// HDR 画像が sdrImage 側に入る。よって `hdrImage ?? sdrImage` を HDR ソースとし、
// SDR 版は `SDRConversion` で自前生成する。
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

/// 撮影 API が画像を返さなかった。
private enum CaptureImageError: LocalizedError {
    case missingImage

    var errorDescription: String? {
        switch self {
        case .missingImage: "画像が取得できませんでした。"
        }
    }
}

/// キャプチャ結果。画像とその倍率を組にして持つ。
///
/// `CGImage` は自身が何倍で撮られたかを持たない。CAP-02 で Retina では
/// ポイントの `backingScaleFactor` 倍のピクセル数を要求しているため、
/// ピクセル数だけを表示側に渡すと「画面で見えていた大きさ」が復元できず、
/// 2x 環境で 2 倍の大きさに表示されてしまう。倍率を一緒に運ぶ。
struct CaptureResult {
    /// 撮影した画像（ピクセル）。
    let image: CGImage
    /// 1 ポイントあたりのピクセル数（Retina なら 2.0）。
    let scale: CGFloat
    /// HDR 版（拡張 sRGB・16bit float。1.0 超の明部を含む）。
    ///
    /// HDR 非対応の環境や、実質 SDR のとき（`HDRAvailability` が判定）は nil。
    /// `image`（SDR 版。HDR ソースから `SDRConversion` で作ったもの）と同じピクセル寸法・同じ範囲を写している。OCR は常に `image` を使う。
    let hdrImage: CGImage?

    init(image: CGImage, scale: CGFloat, hdrImage: CGImage? = nil) {
        self.image = image
        self.scale = scale
        self.hdrImage = hdrImage
    }

    /// 画面上で見えていた大きさ（ポイント）。
    ///
    /// 倍率が異常値（0 以下）なら等倍とみなしてピクセル寸法を返す。
    /// ここを素通しにすると 0 除算で無限大や負の寸法が生まれ、そのまま
    /// `NSWindow.setContentSize` やレイアウトへ渡ってしまう。
    /// 寸法計算はすべてここを通るので、ガードはこの 1 か所で足りる。
    var pointSize: CGSize {
        guard scale > 0 else { return pixelSize }
        return CGSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale
        )
    }

    /// 画像のピクセル寸法。保存・コピーされる実データのサイズ。
    var pixelSize: CGSize {
        CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
    }
}

/// キャプチャの対象。範囲選択とウィンドウ選択を 1 つの結果型で扱う。
///
/// SelectionCoordinator の完了ハンドラが「矩形 or ウィンドウ or キャンセル」を
/// 返せるようにするためのもの。Optional の CGRect だけでは表現できない。
enum CaptureTarget {
    /// ドラッグで選択した矩形（AppKit グローバル座標）。
    case region(CGRect)
    /// クリックで選択したウィンドウ（CAP-06）。
    case window(SCWindow)
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
    /// - Returns: Retina 解像度を維持した画像と、その倍率（CAP-02）。
    static func capture(
        appKitRect: CGRect,
        content preloaded: SCShareableContent? = nil
    ) async throws -> CaptureResult {
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

        let config = SCScreenshotConfiguration()
        config.sourceRect = sourceRect
        // CAP-02: ポイントの backingScale 倍のピクセル数を要求して
        // Retina 解像度のまま取得する（ダウンスケールさせない）。
        //
        // 旧 SCStreamConfiguration の captureResolution = .best / scalesToFit = false は
        // SCScreenshotConfiguration に存在しない。代わりに width/height を
        // 「sourceRect のポイント × backingScale」の整数ピクセルで明示し、
        // 撮影範囲と出力ピクセルを 1:1 にして等倍を担保する
        // （sourceRect は上で整数に丸め済みなので補間も入らない）。
        let scale = screen.backingScaleFactor
        config.width = Int((sourceRect.width * scale).rounded())
        config.height = Int((sourceRect.height * scale).rounded())
        config.showsCursor = false
        config.dynamicRange = .bothSDRAndHDR
        config.displayIntent = Self.displayIntent

        return try await screenshot(
            filter: filter, config: config, scale: scale,
            displayMaxEDR: screen.maximumPotentialExtendedDynamicRangeColorComponentValue,
            displayColorSpace: Self.displayColorSpace(of: screen),
            shadow: false)
    }

    /// 表示意図。`.local` = 撮ったディスプレイの見え方のまま。
    ///
    /// `.canonical`（標準ディスプレイ基準）にすると、画面で見ていた色・明るさと
    /// 変わって見える。このアプリは「画面で見えたものをそのまま画像にする」ので
    /// `.local` を基本にする。
    private static let displayIntent: SCScreenshotConfiguration.DisplayIntent = .local

    /// 撮影して SDR/HDR を CaptureResult にまとめる。
    ///
    /// ★画像処理（HDR 判定・影の合成）は MainActor の外で行う。HDR 判定は CIContext による
    /// GPU 処理と読み戻し、影は Retina 大画像のぼかし描画を SDR・HDR の 2 回で、どれも
    /// メインスレッドで走らせると UI が止まる。`SCScreenshotOutput` は Sendable でないので、
    /// MainActor 側で CGImage（Sendable）だけを取り出して渡す。NSScreen の EDR 値も
    /// MainActor でしか読めないため、呼び出し側で読んだ値を受け取っている。
    private static func screenshot(
        filter: SCContentFilter,
        config: SCScreenshotConfiguration,
        scale: CGFloat,
        displayMaxEDR: CGFloat,
        displayColorSpace: CGColorSpace,
        shadow: Bool
    ) async throws -> CaptureResult {
        let output: SCScreenshotOutput
        do {
            output = try await SCScreenshotManager.captureScreenshot(
                contentFilter: filter, configuration: config)
        } catch {
            throw CaptureError.captureFailed(error)
        }
        // 実測どおり sdrImage は SDR ではないので、HDR ソースは hdrImage 優先で取る。
        guard let source = output.hdrImage ?? output.sdrImage else {
            throw CaptureError.captureFailed(CaptureImageError.missingImage)
        }
        do {
            return try await postProcess(
                source: source, maxEDR: displayMaxEDR, displayColorSpace: displayColorSpace,
                shadow: shadow, scale: scale)
        } catch {
            // SDRConversionError（カーネル未読込／描画失敗）の文言をそのまま利用者へ渡す。
            throw CaptureError.captureFailed(error)
        }
    }

    /// SDR 版の色空間にするディスプレイの色空間。
    /// 画面が無い・取れない、または出力に使えない空間（RGB でない・出力不可）なら Display P3 → sRGB。
    private static func displayColorSpace(of screen: NSScreen?) -> CGColorSpace {
        if let cs = screen?.colorSpace?.cgColorSpace, cs.supportsOutput, cs.model == .rgb {
            return cs
        }
        return CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// 撮影後の画像処理。MainActor の外（グローバル並行プール）で実行する。
    ///
    /// SDR 版を作れなければ `SDRConversionError` を投げる（黙って違う絵にしない）。
    @concurrent
    nonisolated private static func postProcess(
        source: CGImage, maxEDR: CGFloat, displayColorSpace: CGColorSpace,
        shadow: Bool, scale: CGFloat
    ) async throws -> CaptureResult {
        let sdr: CGImage
        let resolvedHDR: CGImage?
        switch SDRConversion.plan(for: source) {
        case .convertFromHDR:
            sdr = try SDRConversion.makeSDR(from: source, colorSpace: displayColorSpace)
            // HDR ソースが実質 SDR（明部が無い／ディスプレイが HDR 非対応）なら nil にする。
            resolvedHDR = HDRAvailability.resolve(source, displayMaxEDR: maxEDR)
        case .useAsSDR:
            // Intel Mac などで 8bit が来た。そのまま SDR 版とし、HDR 版は無し。
            sdr = source
            resolvedHDR = nil
        }

        // CAP-07: 影は等倍で撮った画像の上に合成する。
        //
        // 影の余白もポイント基準の値に scale を掛けて描くので、合成後も
        // 「1 ポイント = scale ピクセル」の関係は保たれる。倍率は変わらない。
        // SDR 版にも HDR 版にも同じ影を付ける（形式は元画像に合わせて合成される）。
        guard shadow else { return CaptureResult(image: sdr, scale: scale, hdrImage: resolvedHDR) }
        return CaptureResult(
            image: ShadowCompositor.addShadow(to: sdr, scale: scale),
            scale: scale,
            hdrImage: resolvedHDR.map { ShadowCompositor.addShadow(to: $0, scale: scale) })
    }

    /// 指定したウィンドウ 1 つをキャプチャする（CAP-06 / CAP-07）。
    /// - Parameters:
    ///   - window: 対象ウィンドウ。
    ///   - includeShadow: ドロップシャドウを付けるか（CAP-07、設定で選べる）。
    /// - Returns: Retina 解像度を維持した画像と、その倍率。
    static func capture(
        window: SCWindow,
        includeShadow: Bool
    ) async throws -> CaptureResult {
        // desktopIndependentWindow フィルタは対象ウィンドウだけを切り出す。
        // 背後のウィンドウや壁紙は写らず、重なりも無視できる（sourceRect 方式では
        // 手前のウィンドウが写り込んでしまう）。
        let filter = SCContentFilter(desktopIndependentWindow: window)

        let config = SCScreenshotConfiguration()
        // ★影は ScreenCaptureKit に任せない（常に true = 影を除外して撮る）。
        //
        // ignoreShadows = false にすれば影付きで撮れるが、
        // 撮影範囲が広がるのに contentRect は影を含まない範囲を返すため、
        // 内容が縮小されてぼやける（実測: 鮮明度 7.684 → 4.625。旧 API での値）。
        // 影が必要な場合は ShadowCompositor で後から合成する。
        config.ignoreShadows = true
        config.showsCursor = false
        config.dynamicRange = .bothSDRAndHDR
        config.displayIntent = Self.displayIntent

        // CAP-02: Retina 解像度を維持する。
        //
        // 旧 API の captureResolution / scalesToFit は新 API に無い。指定した
        // width/height に内容が合わせ込まれるため、実際の撮影範囲と一致して
        // いなければスケーリングが入る。影を除外した今、撮影範囲は contentRect と
        // 一致するので contentRect × pointPixelScale で等倍になる。
        // width/height を省略すると既定サイズ（出力はコンテンツ寸法）に依存して
        // 等倍が保証できないため、明示する。
        let scale = CGFloat(filter.pointPixelScale)
        let contentSize = filter.contentRect.size
        config.width = Int((contentSize.width * scale).rounded())
        config.height = Int((contentSize.height * scale).rounded())

        // HDR 判定と SDR 版の色空間に使うディスプレイ。ウィンドウの載っている画面。
        let windowScreen = ScreenGeometry.screen(
            containing: ScreenGeometry.convertToAppKit(window.frame)) ?? NSScreen.main
        return try await screenshot(
            filter: filter, config: config, scale: scale,
            displayMaxEDR: windowScreen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1,
            displayColorSpace: Self.displayColorSpace(of: windowScreen),
            shadow: includeShadow)
    }
}
