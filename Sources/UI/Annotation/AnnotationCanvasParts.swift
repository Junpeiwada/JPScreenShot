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

    /// SDR 版（常にある）。
    private(set) var image: CGImage?
    /// HDR 版の元画像（拡張 sRGB・half float）。無ければ HDR 表示はできない。
    private var hdrSource: CGImage?
    /// HDR 版を PQ に焼いた表示用画像。初めて HDR にしたときに 1 回だけ作り、以後は使い回す
    /// （SDR/HDR を切り替えるたびに焼き直さない。焼きは GPU でも画像サイズ次第で数十 ms かかる）。
    private var bakedHDR: CGImage?
    /// いま表示している版。
    private(set) var dynamicRange: ImageDynamicRange = .sdr

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

    /// 元画像を渡す。`hdr` があれば `setDynamicRange(.hdr)` で HDR 表示にできる。
    func setImage(_ image: CGImage, hdr: CGImage? = nil) {
        self.image = image
        hdrSource = hdr
        bakedHDR = nil
        applyDynamicRange()
    }

    /// 表示する版を切り替える。HDR 版が無い（または焼けない）ときは SDR のまま。
    /// 切替で触るのはレイヤーの contents と EDR 設定だけで、注釈・倍率・選択には影響しない。
    func setDynamicRange(_ range: ImageDynamicRange) {
        guard range != dynamicRange else { return }
        dynamicRange = range
        applyDynamicRange()
    }

    /// 実際に HDR で出しているか（HDR を要求され、かつ焼けた）。
    private(set) var isShowingHDR = false

    /// HDR を要求されたが焼けず、SDR 表示に戻したときの通知。
    ///
    /// 呼び出し側（キャンバス）が `editor.dynamicRange` を `.sdr` に戻すために使う。戻さないと、
    /// 画面は SDR なのにセグメントは HDR のままで、保存・コピー（`dynamicRange` に従う）だけが
    /// HDR になり、見ているものと書き出すものが食い違う。
    var onHDRBakeFailed: (() -> Void)?

    /// contents と EDR 設定を、いまの版に合わせる。
    ///
    /// HDRForge で実証済みの条件（知見-GUI 3）:
    /// - 画像は ITU-R 2100 PQ・16bit・`calculateHDRStats` 付きで焼く（`HDRDisplayBaker`）。
    /// - `preferredDynamicRange = .high` を画像レイヤーと親レイヤーに付ける（EDR は画面単位の
    ///   スイッチで、他者の要求への相乗りだと窓構成の変化で SDR に落ちる。自分でも要求する）。
    /// - `toneMapMode = .never`（PQ は絶対輝度なので、OS がもう一度トーンマップすると二重になる）。
    ///
    /// 焼きは初回の HDR 表示でメインスレッド上で同期に行う。撮影直後に 1 回だけで、
    /// GPU 実行（`deferred: false`）なのでメインを塞ぐのは画像サイズ次第で数十 ms 程度。
    /// 非同期にすると SDR が一瞬見えてから HDR に変わるちらつきが出るため、同期を選んだ。
    private func applyDynamicRange() {
        var baked: CGImage?
        if dynamicRange == .hdr, let hdrSource {
            if bakedHDR == nil { bakedHDR = HDRDisplayBaker.bake(hdrSource) }
            baked = bakedHDR
        }
        let useHDR = baked != nil
        isShowingHDR = useHDR
        if dynamicRange == .hdr, hdrSource != nil, !useHDR {
            NSLog("JPScreenShot: HDR 表示用の画像を作れませんでした（PQ への変換に失敗）。SDR 表示に戻します")
            onHDRBakeFailed?()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = baked ?? image
        let range: CALayer.DynamicRange = useHDR ? .high : .standard
        for target in [layer, imageLayer] {
            target?.preferredDynamicRange = range
            target?.toneMapMode = useHDR ? .never : .automatic
        }
        CATransaction.commit()
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
