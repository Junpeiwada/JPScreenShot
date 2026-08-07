import CoreGraphics
import Testing

@testable import JPScreenShot

// ポイントとピクセルの取り違えは実際に不具合を起こした箇所。
//
// 以前は撮影画像を「1 ピクセル = 1 ポイント」として表示していたため、
// Retina（2x）で撮ったスクリーンショットが画面の 2 倍の大きさで
// 表示されていた。ウィンドウの初期サイズや縮小表示の判定もすべて
// この寸法を基準にするので、回帰したときの影響が広い。
//
// 計算自体は image の縦横と scale だけに依存する純粋関数であり、
// 画面収録の権限は要らない。
@Suite("キャプチャ結果の寸法")
struct CaptureResultTests {

    /// 指定したピクセル寸法のダミー画像。中身は問わない。
    private func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    @Test("1x ではポイントとピクセルが一致する")
    func 等倍() {
        let result = CaptureResult(image: makeImage(width: 300, height: 200), scale: 1)
        #expect(result.pixelSize == CGSize(width: 300, height: 200))
        #expect(result.pointSize == CGSize(width: 300, height: 200))
    }

    @Test("2x ではポイントがピクセルの半分になる")
    func レティナ() {
        // 600×400 ピクセルで撮れた画像は、画面上では 300×200 ポイントの
        // 範囲だった。表示もウィンドウ寸法もこちらを基準にする。
        let result = CaptureResult(image: makeImage(width: 600, height: 400), scale: 2)
        #expect(result.pixelSize == CGSize(width: 600, height: 400))
        #expect(result.pointSize == CGSize(width: 300, height: 200))
    }

    @Test("倍率が異常でも寸法が壊れない", arguments: [CGFloat(0), -1, -2])
    func 異常な倍率(scale: CGFloat) {
        // 0 で割ると無限大、負で割ると負の寸法になり、そのまま
        // NSWindow.setContentSize やレイアウトへ渡ってしまう。
        // 等倍とみなして退避する。
        let result = CaptureResult(image: makeImage(width: 100, height: 50), scale: scale)
        #expect(result.pointSize == CGSize(width: 100, height: 50))
        #expect(result.pointSize.width.isFinite)
        #expect(result.pointSize.height > 0)
    }

    @Test("非整数の倍率でも比が保たれる")
    func 小数の倍率() {
        // 1.5x など整数でない backingScaleFactor を持つ構成もある。
        let result = CaptureResult(image: makeImage(width: 300, height: 150), scale: 1.5)
        #expect(abs(result.pointSize.width - 200) < 0.001)
        #expect(abs(result.pointSize.height - 100) < 0.001)
    }
}
