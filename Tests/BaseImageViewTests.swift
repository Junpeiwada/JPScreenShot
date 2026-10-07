import AppKit
import Testing

@testable import JPScreenShot

// 撮った画像が結果ウィンドウに実際に描かれることの回帰テスト。
//
// 以前は元画像をビュー自身のレイヤー（backing layer）の contents に置いていたため、
// ウィンドウに出した後の再描画で AppKit が contents を自前の描画バッファで上書きし、
// 画像が真っ白に表示されていた（保存・コピーは元画像を直接使うので正常だった）。
// レイヤーの中身を見るだけでは表示前の状態しか分からないので、実際に結果ウィンドウを
// 出して描画させ、画素の色で確かめる。
@MainActor
@Suite("元画像の表示")
struct BaseImageViewTests {

    /// 上半分が赤・下半分が青の画像（2x 想定）。
    private func makeImage() -> CGImage {
        let width = 400, height = 240
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CGContext は左下原点なので、y の大きい側が画像の上半分。
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        return context.makeImage()!
    }

    private func findView<T: NSView>(_ view: NSView, _ type: T.Type) -> T? {
        if let found = view as? T { return found }
        for subview in view.subviews {
            if let found = findView(subview, type) { return found }
        }
        return nil
    }

    /// レイヤーを描いて、(x, y)（左上原点・ポイント）の色を返す。
    private func color(of layer: CALayer, size: CGSize, at point: CGPoint) -> (r: UInt8, g: UInt8, b: UInt8) {
        let width = Int(size.width), height = Int(size.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            layer.render(in: context)
        }
        // ビットマップのメモリは先頭行が上端。
        let index = (Int(point.y) * width + Int(point.x)) * 4
        return (pixels[index], pixels[index + 1], pixels[index + 2])
    }

    @Test("結果ウィンドウを出したあとも元画像が描かれ、上下の向きも正しい")
    func 元画像が表示される() throws {
        let window = ResultWindow()
        window.show(capture: CaptureResult(image: makeImage(), scale: 2))
        defer { window.close() }
        // 表示と再描画を一巡させる（不具合はこの再描画で起きていた）。
        for _ in 0..<5 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

        let nsWindow = try #require(NSApp.windows.first { $0.isVisible && $0.title == "JPScreenShot" })
        nsWindow.displayIfNeeded()
        let root = try #require(nsWindow.contentView?.superview ?? nsWindow.contentView)
        let base = try #require(findView(root, BaseImageView.self))
        let layer = try #require(base.layer)
        let size = base.bounds.size
        #expect(size == CGSize(width: 200, height: 120))

        let top = color(of: layer, size: size, at: CGPoint(x: size.width / 2, y: size.height * 0.25))
        let bottom = color(of: layer, size: size, at: CGPoint(x: size.width / 2, y: size.height * 0.75))
        #expect(top.r > 200 && top.b < 50, "上半分が赤であること: \(top)")
        #expect(bottom.b > 200 && bottom.r < 50, "下半分が青であること: \(bottom)")
    }
}
