import CoreImage
import Foundation
import Testing

@testable import JPScreenShot

// Debug の -JPSOpenImage が使うゲインマップ画像の読み込み（実装計画-HDR P3-4）。
@Suite("ゲインマップ画像の読み込み")
struct GainMapImageLoaderTests {

    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "gm-\(UUID().uuidString).\(ext)")
    }

    private let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// 左半分が SDR 白（1.0）、右半分が 4 倍の明るさの画像。
    private func hdrImage() -> CIImage {
        let left = CIImage(color: CIColor(red: 1, green: 1, blue: 1, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let right = CIImage(color: CIColor(red: 4, green: 4, blue: 4, colorSpace: space)!)
            .cropped(to: CGRect(x: 100, y: 0, width: 100, height: 100))
        return right.composited(over: left)
    }

    @Test("ゲインマップ付き HEIC は HDR 版も読める")
    func heicWithGainMap() throws {
        let url = tempURL("heic")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = CIContext()
        let sdr = CIImage(color: CIColor(red: 1, green: 1, blue: 1, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        try context.writeHEIFRepresentation(
            of: sdr, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [.hdrImage: hdrImage()])
        let loaded = try #require(GainMapImageLoader.load(url: url))
        #expect(loaded.sdr.width == 200)
        #expect(loaded.hdr != nil)
    }

    @Test("ゲインマップが無い画像は HDR 版 nil")
    func plainPNG() throws {
        let url = tempURL("png")
        defer { try? FileManager.default.removeItem(at: url) }
        let sdr = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 50, height: 50))
        try CIContext().writePNGRepresentation(
            of: sdr, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let loaded = try #require(GainMapImageLoader.load(url: url))
        #expect(loaded.hdr == nil)
    }

    @Test("読めないファイルは nil")
    func missing() {
        #expect(GainMapImageLoader.load(url: tempURL("heic")) == nil)
    }
}
