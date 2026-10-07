import CoreGraphics
import CoreImage
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import JPScreenShot

// 実装計画-HDR P4-1〜P4-4: Metal カーネルの読み込み、ゲインマップ付き HEIC/JPEG、
// PQ の 16bit PNG、SDR 各形式、拡張子。画面収録の権限は要らない（合成画像だけを使う）。
@Suite("画像の書き出し（ImageExporter）")
struct ImageExporterTests {

    private let width = 64, height = 32

    /// SDR 版（Display P3・8bit）。左半分は 0.2 の灰色、右半分は白。
    private func makeSDR(alpha: CGFloat = 1) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: space, components: [0.2, 0.2, 0.2, alpha])!)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, alpha])!)
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        return context.makeImage()!
    }

    /// HDR 版（拡張リニア sRGB・16bit float）。左半分は SDR と同じ明るさ、右半分は `peak`
    /// （SDR 白の `peak` 倍。既定 4.0）。
    ///
    /// リニア空間で作るのは、値がそのまま「SDR 白の何倍か」になり、読み戻しの期待値
    /// （peak）を換算なしで書けるため。拡張 sRGB（ガンマ付き）だと 4.0 は約 12 倍の光になる。
    private func makeHDR(peak: CGFloat = 4) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0,
            space: space, bitmapInfo: HDRPixelFormat.hdrBitmapInfo)!
        // 0.2（ガンマ付き）のリニア値 ≈ 0.033。SDR の左半分と同じ光にする。
        context.setFillColor(CGColor(colorSpace: space, components: [0.033, 0.033, 0.033, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(colorSpace: space, components: [peak, peak, peak, 1])!)
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        return context.makeImage()!
    }

    /// 書き出したデータを HDR として読み戻した画素（拡張リニア sRGB、RGBA の Float 配列）。
    private func decodedPixels(_ data: Data) throws -> [Float] {
        let ci = try #require(CIImage(data: data, options: [.expandToHDR: true]))
        let context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAh.rawValue,
        ])
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            context.render(ci, toBitmap: raw.baseAddress!, rowBytes: width * 16,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        }
        return pixels
    }

    /// 書き出したデータを HDR として読み戻したときの最大 R（1.0 = SDR 白）。
    private func decodedPeak(_ data: Data) throws -> Float {
        let pixels = try decodedPixels(data)
        return stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }.max() ?? 0
    }

    private func image(from data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    // MARK: - P4-1/2: Metal カーネル

    @Test("default.metallib を読めて、ゲインマップ用の 3 カーネルとメタデータの借用元が作れる")
    func kernelsLoad() {
        #expect(MetalKernelLibrary.data != nil)
        #expect(ColorGainMap.templateKernel != nil)
        #expect(ColorGainMap.logGainKernel != nil)
        #expect(ColorGainMap.gainMapKernel != nil)
        #expect(ColorGainMap.template != nil)
        #expect(ColorGainMap.makeMetadata(maxLog2: 2) != nil)
    }

    // MARK: - P4-3/4: HDR

    @Test("HDR の HEIC はカラーゲインマップを持ち、HDR として読み戻すと 1.0 を超える")
    func hdrHEIC() throws {
        let data = try ImageExporter.export(
            format: .heic, dynamicRange: .hdr, sdr: makeSDR(), hdr: makeHDR())
        #expect(ImageExporter.hasGainMap(data))
        #expect(ColorGainMap.isColorGainMap(data: data))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.heic.identifier)
        let peak = try decodedPeak(data)
        // リニア 4 倍で作ったので、ゲインマップで 4 倍近くまで復元される（量子化の誤差だけ許す）。
        #expect(abs(peak - 4) < 0.3, "peak=\(peak)")
    }

    @Test("HDR の HEIC は半透明の画素があっても書ける（ウィンドウ影つきの撮影）")
    func hdrHEICWithAlpha() throws {
        let data = try ImageExporter.export(
            format: .heic, dynamicRange: .hdr, sdr: makeSDR(alpha: 0.5), hdr: makeHDR())
        #expect(ColorGainMap.isColorGainMap(data: data))
    }

    @Test("HDR の JPEG はゲインマップを持ち、HDR として読み戻すと 1.0 を超える")
    func hdrJPEG() throws {
        let data = try ImageExporter.export(
            format: .jpeg, dynamicRange: .hdr, sdr: makeSDR(), hdr: makeHDR())
        #expect(ImageExporter.hasGainMap(data))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let peak = try decodedPeak(data)
        #expect(abs(peak - 4) < 0.3, "peak=\(peak)")
    }

    @Test("HEIC のゲイン上限（16 倍）で頭打ちになる。リニア 32 倍の HDR 版は 16 倍付近に収まる")
    func gainCeiling() throws {
        // JPEG は CoreImage 自前のゲインマップ（`.hdrImage`）で、上限は ColorGainMap の管轄外なので対象にしない。
        let data = try ImageExporter.export(
            format: .heic, dynamicRange: .hdr, sdr: makeSDR(), hdr: makeHDR(peak: 32))
        let peak = try decodedPeak(data)
        #expect(peak > 12 && peak < 20, "peak=\(peak)")
    }

    // MARK: - offset（1/64）の回帰

    @Test("offset は 1/64")
    func offsetIsOneSixtyFourth() {
        #expect(ColorGainMap.offset == 1.0 / 64.0)
    }

    @Test("8bit 化で暗部が 0 に丸められた SDR ベースでも、ゲイン上限は実測値（≈2）で 4.0 に張り付かない")
    func measureMaxLog2WithQuantizedDarkBase() throws {
        // ベース: 暗い色（成分が 8bit で 0 に落ちる (0, 0.0005 級)）と明部（リニア 1.0）。
        // HDR: 暗部はベースと同じ光（ただし連続値 0.002）、明部はリニア 4 倍 → 本来の最大ゲインは log2(4)=2。
        // offset が 1e-5 だと、ベース側 0 に対する HDR 側 0.002 で log2 比が 7 段超になり上限 4.0 に張り付いていた。
        let p3Linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let n = 8
        // 8bit の拡張リニア色空間は CGContext が作れない（nil）ので、8bit ベースは通常の Display P3 で持つ。
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        func make(_ pixels: [[Float]], bits: Int) -> CGImage {
            let ctx = CGContext(
                data: nil, width: n, height: 1, bitsPerComponent: bits, bytesPerRow: 0,
                space: bits == 8 ? p3 : p3Linear, bitmapInfo: bits == 8
                    ? CGImageAlphaInfo.premultipliedLast.rawValue : HDRPixelFormat.hdrBitmapInfo)!
            for (x, px) in pixels.enumerated() {
                ctx.setFillColor(CGColor(colorSpace: p3Linear, components: [
                    CGFloat(px[0]), CGFloat(px[1]), CGFloat(px[2]), 1])!)
                ctx.fill(CGRect(x: x, y: 0, width: 1, height: 1))
            }
            return ctx.makeImage()!
        }
        // ベースの暗部は 8bit で 0 に丸められた状態（0）、HDR 側は同じ光を連続値（0.002 級）で持つ。
        let dark: [Float] = [0.002, 0.0005, 0.0]
        let bright: [Float] = [1, 1, 1]
        let baseImage = make(
            Array(repeating: [0, 0, 0], count: 4) + Array(repeating: bright, count: 4), bits: 8)
        let hdrImage = make(
            Array(repeating: dark, count: 4) + Array(repeating: [4, 4, 4], count: 4), bits: 16)
        let context = CIContext(options: [
            .workingColorSpace: p3Linear, .workingFormat: CIFormat.RGBAf.rawValue,
        ])
        let peak = ColorGainMap.measureMaxLog2(
            base: CIImage(cgImage: baseImage), hdr: CIImage(cgImage: hdrImage), context: context)
        #expect(peak > 1.8 && peak < 2.2, "peak=\(peak)")
    }

    @Test("書いた HDR HEIC の metadata の BaseOffset / AlternateOffset は ColorGainMap.offset と一致する")
    func metadataOffsetsMatch() throws {
        let data = try ImageExporter.export(
            format: .heic, dynamicRange: .hdr, sdr: makeSDR(), hdr: makeHDR())
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let aux = try #require(
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap)
                as? [String: Any])
        let meta = try #require(aux[kCGImageAuxiliaryDataInfoMetadata as String])
        let md = meta as! CGImageMetadata
        for name in ["BaseOffset", "AlternateOffset"] {
            let value = try #require(
                CGImageMetadataCopyStringValueWithPath(
                    md, nil, "HDRToneMap:ChannelMetadata[0].HDRToneMap:\(name)" as CFString)
                    as String?)
            #expect(abs((Double(value) ?? -1) - ColorGainMap.offset) < 1e-5, "\(name)=\(value)")
        }
    }

    @Test("SDR と同じ光の HDR 版（ゲイン≈1）は、HDR HEIC として読み戻しても色が変わらない")
    func hdrHEICKeepsColor() throws {
        // SDR は Display P3 の純赤。HDR 版は同じ色を拡張 sRGB で表したもの（P3 赤は sRGB の外なので
        // 成分に 1 超・負が出る）。両者は同じ光なので、ゲインは 1 で、読み戻しの色は SDR と一致するはず。
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let red = CGColor(colorSpace: p3, components: [1, 0, 0, 1])!
        let sdrContext = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: p3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        sdrContext.setFillColor(red)
        sdrContext.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let extended = CGColorSpace(name: CGColorSpace.extendedSRGB)!
        let hdrContext = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0,
            space: extended, bitmapInfo: HDRPixelFormat.hdrBitmapInfo)!
        hdrContext.setFillColor(try #require(red.converted(to: extended, intent: .defaultIntent, options: nil)))
        hdrContext.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let data = try ImageExporter.export(
            format: .heic, dynamicRange: .hdr, sdr: sdrContext.makeImage()!, hdr: hdrContext.makeImage()!)
        let pixels = try decodedPixels(data)
        let expected = try #require(
            red.converted(to: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, intent: .defaultIntent, options: nil)?
                .components)
        let i = (height / 2 * width + width / 2) * 4
        for c in 0..<3 {
            #expect(abs(pixels[i + c] - Float(expected[c])) < 0.1,
                    "ch\(c): \(pixels[i + c]) vs \(expected[c])")
        }
    }

    @Test("HDR の PNG は ITU-R 2100 PQ・16bit で、ゲインマップは持たない")
    func hdrPNG() throws {
        let data = try ImageExporter.export(
            format: .png, dynamicRange: .hdr, sdr: makeSDR(), hdr: makeHDR())
        let decoded = try image(from: data)
        #expect(decoded.colorSpace?.name as String? == (CGColorSpace.itur_2100_PQ as String))
        #expect(decoded.bitsPerComponent == 16)
        #expect(!ImageExporter.hasGainMap(data))
    }

    @Test("HDR を求められて HDR 版が無い・寸法が違うときは SDR に落とさず失敗する")
    func hdrFailures() {
        #expect(throws: ExportError.hdrImageMissing) {
            try ImageExporter.export(format: .png, dynamicRange: .hdr, sdr: makeSDR(), hdr: nil)
        }
        let small = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 16, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.extendedSRGB)!, bitmapInfo: HDRPixelFormat.hdrBitmapInfo
        )!.makeImage()!
        #expect(throws: ExportError.sizeMismatch) {
            try ImageExporter.export(format: .heic, dynamicRange: .hdr, sdr: makeSDR(), hdr: small)
        }
    }

    // MARK: - SDR

    @Test("SDR の PNG は 8bit でゲインマップ無し")
    func sdrPNG() throws {
        let data = try ImageExporter.export(
            format: .png, dynamicRange: .sdr, sdr: makeSDR(), hdr: makeHDR())
        let decoded = try image(from: data)
        #expect(decoded.bitsPerComponent == 8)
        #expect(decoded.width == width && decoded.height == height)
        #expect(!ImageExporter.hasGainMap(data))
    }

    @Test("SDR の HEIC・JPEG は期待どおりの形式でゲインマップ無し（HDR 版があっても SDR を選べば無し）")
    func sdrHEICAndJPEG() throws {
        for (format, type) in [(ImageExporter.Format.heic, UTType.heic), (.jpeg, .jpeg)] {
            let data = try ImageExporter.export(
                format: format, dynamicRange: .sdr, sdr: makeSDR(), hdr: makeHDR())
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            #expect(CGImageSourceGetType(source) as String? == type.identifier)
            #expect(!ImageExporter.hasGainMap(data))
            let decoded = try image(from: data)
            #expect(decoded.width == width && decoded.height == height)
        }
    }

    @Test("SDR の JPEG は透明部を白に敷く")
    func sdrJPEGFlattensAlpha() throws {
        let clear = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let data = try ImageExporter.export(format: .jpeg, dynamicRange: .sdr, sdr: clear, hdr: nil)
        let decoded = try image(from: data)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(pixel[0] > 240 && pixel[1] > 240 && pixel[2] > 240)
    }

    // MARK: - 形式

    @Test("拡張子・UTType の対応")
    func formatMapping() {
        #expect(ImageExporter.Format.heic.fileExtension == "heic")
        #expect(ImageExporter.Format.png.fileExtension == "png")
        #expect(ImageExporter.Format.jpeg.fileExtension == "jpg")
        #expect(ImageExporter.Format.jpeg.type == .jpeg)
        #expect(ImageExporter.Format.allCases.map(\.label) == ["HEIC", "PNG", "JPG"])
    }
}
