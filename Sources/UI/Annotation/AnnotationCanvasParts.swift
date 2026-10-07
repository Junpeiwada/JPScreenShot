import AppKit

// MARK: - 描画の部品

/// 元画像を出すビュー。専用の CALayer の contents に CGImage を置くだけで、描画コードは持たない。
/// マウスは通さず（`hitTest` が nil）、キャンバス本体が受ける。
///
/// 画像はビュー自身のレイヤー（backing layer）ではなく、その上に足した**専用のサブレイヤー**に置く。
/// backing layer は AppKit の管理下にあり、再描画のたびに contents を自前の描画バッファ
/// （CABackingStore）で上書きするため、そこに置いた画像は消えて真っ白になる（実際に起きた不具合）。
/// AppKit は自分で足したサブレイヤーには触らない。
///
/// 非 flipped にしてある。flipped のビューのレイヤーに CGImage を置くと
/// 上下の向きの扱いが環境で変わりうるため、向きが確実な通常のビューにしている。
@MainActor
final class BaseImageView: NSView {

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private(set) var image: CGImage?

    /// 画像を載せるサブレイヤー。
    let imageLayer: CALayer = {
        let layer = CALayer()
        // 縮小表示でも荒れないよう、縮小は mipmap 付きの補間（従来の .high 相当）。
        // 等倍のときは 1 ピクセル = 1 ピクセルなので補間は効かない。
        layer.contentsGravity = .resize
        layer.minificationFilter = .trilinear
        layer.magnificationFilter = .linear
        layer.isOpaque = true
        return layer
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(imageLayer)
        imageLayer.frame = bounds
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 元画像を渡す。
    func setImage(_ image: CGImage) {
        self.image = image
        imageLayer.contents = image
    }

    /// ビューの大きさ（表示倍率）に画像を合わせる。暗黙のアニメーションは切る。
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
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
