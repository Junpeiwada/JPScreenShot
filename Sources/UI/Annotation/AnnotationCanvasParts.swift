import AppKit

// MARK: - 描画の部品

/// 元画像を出すビュー。CALayer の contents に CGImage を置くだけで、描画コードは持たない。
/// マウスは通さず（`hitTest` が nil）、キャンバス本体が受ける。
///
/// 非 flipped にしてある。flipped のビューのレイヤーに CGImage を直接置くと
/// 上下の向きの扱いが環境で変わりうるため、向きが確実な通常のビューにしている。
@MainActor
final class BaseImageView: NSView {

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var image: CGImage?

    func setImage(_ image: CGImage) {
        self.image = image
        wantsLayer = true
        needsDisplay = true
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        // 縮小表示でも荒れないよう、縮小は mipmap 付きの補間（従来の .high 相当）。
        // 等倍のときは 1 ピクセル = 1 ピクセルなので補間は効かない。
        layer.contentsGravity = .resize
        layer.minificationFilter = .trilinear
        layer.magnificationFilter = .linear
        layer.isOpaque = true
        return layer
    }

    override func updateLayer() {
        layer?.contents = image
    }
}

/// 注釈と選択枠を描くビュー。元画像の上に重ね、背景は透明。
/// 座標系はキャンバスと同じ（flipped・左上原点）。マウスは通す。
@MainActor
final class AnnotationOverlayView: NSView {

    weak var canvas: AnnotationCanvasView?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        canvas?.drawContent(in: context)
    }
}

// MARK: - 補助

extension CGRect {
    /// 原点も大きさも等倍して返す（注釈座標 → ビュー座標）。
    func scaled(by factor: CGFloat) -> CGRect {
        CGRect(
            x: origin.x * factor, y: origin.y * factor,
            width: size.width * factor, height: size.height * factor)
    }
}
