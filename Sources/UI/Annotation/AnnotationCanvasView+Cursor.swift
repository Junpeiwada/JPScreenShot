import AppKit

// AnnotationCanvasView のカーソル。

extension AnnotationCanvasView {

    // MARK: カーソル

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        refreshCursor(atWindowPoint: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        setHoverCursor(.arrow)
    }

    /// カーソル矩形で出す。ビュー全体に 1 つの矩形を張り、形は `hoverCursor` で切り替える。
    /// 形が変わったら矩形を無効化して張り直させる（SwiftUI 側のカーソル管理に
    /// 上書きされないようにするため、`set()` だけに頼らない）。
    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: hoverCursor)
    }

    func setHoverCursor(_ cursor: NSCursor) {
        if cursor !== hoverCursor {
            hoverCursor = cursor
            window?.invalidateCursorRects(for: self)
        }
        // ドラッグ中はカーソル矩形が評価されないので、直接も設定する。
        cursor.set()
    }

    /// ウィンドウ座標のマウス位置からカーソルを決め直す。
    func refreshCursor(atWindowPoint windowPoint: NSPoint? = nil) {
        guard let window else { return }
        let location = windowPoint ?? window.mouseLocationOutsideOfEventStream
        let local = convert(location, from: nil)
        guard bounds.contains(local) else { return }
        let point = AnnotationInteraction.annotationPoint(fromView: local, scale: viewScale)
        setHoverCursor(cursor(at: point))
    }

    /// ドラッグ中のカーソル。移動中は握った手、新規作成・範囲選択は十字。
    func updateCursorForCurrentInteraction() {
        switch interaction {
        case .move: setHoverCursor(.closedHand)
        case .create: setHoverCursor(Self.createCursor)
        case .marquee: setHoverCursor(.arrow)
        case .resize(_, let handle, _, _): setHoverCursor(Self.cursor(for: handle))
        case .idle: break
        }
    }

    /// 押さずに乗せたときのカーソル。mouseDown と同じ `pressTarget` / `pressAction` を通すので、
    /// 表示と押したときの動きがずれない。
    private func cursor(at point: CGPoint) -> NSCursor {
        let shift = NSEvent.modifierFlags.contains(.shift)
        switch AnnotationInteraction.pressAction(
            for: pressTarget(at: point), mode: pressMode, shift: shift)
        {
        case .resize(let handle, _): return Self.cursor(for: handle)
        // 選択中のもの。動かせる。テキストツールはクリックで編集になるので I ビームのまま。
        case .moveSelected: return editor.tool == .text ? .iBeam : .openHand
        // 未選択のもの。押せば選べる。
        case .pickObject, .toggleSelection: return .pointingHand
        case .nothing: return .arrow
        case .textOnObject, .placeText: return .iBeam
        // 新規作成になる場所。
        case .create: return Self.createCursor
        case .marquee: return .arrow
        }
    }

    /// 新規作成の場所のカーソル。十字に小さな「+」を添える。白い縁取りで明暗どちらの画像でも見える。
    /// 描画は表示倍率ごとに行われるので Retina でもくっきりする。一度だけ作って使い回す。
    private static let createCursor: NSCursor = {
        let size = NSSize(width: 24, height: 24)
        let center = CGPoint(x: 10, y: 10)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            func cross(at c: CGPoint, arm: CGFloat) {
                let path = CGMutablePath()
                path.move(to: CGPoint(x: c.x - arm, y: c.y))
                path.addLine(to: CGPoint(x: c.x + arm, y: c.y))
                path.move(to: CGPoint(x: c.x, y: c.y - arm))
                path.addLine(to: CGPoint(x: c.x, y: c.y + arm))
                context.setLineCap(.round)
                context.addPath(path)
                context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
                context.setLineWidth(3)
                context.strokePath()
                context.addPath(path)
                context.setStrokeColor(CGColor(gray: 0, alpha: 1))
                context.setLineWidth(1)
                context.strokePath()
            }
            cross(at: center, arm: 8)
            cross(at: CGPoint(x: 19, y: 19), arm: 3)
            return true
        }
        return NSCursor(image: image, hotSpot: center)
    }()

    private static func cursor(for handle: AnnotationGeometry.Handle) -> NSCursor {
        let position: NSCursor.FrameResizePosition
        switch handle {
        case .topLeft: position = .topLeft
        case .top: position = .top
        case .topRight: position = .topRight
        case .right: position = .right
        case .bottomRight: position = .bottomRight
        case .bottom: position = .bottom
        case .bottomLeft: position = .bottomLeft
        case .left: position = .left
        // 線・矢印の端点は向きを持たないので十字。
        case .start, .end: return .crosshair
        }
        return .frameResize(position: position, directions: .all)
    }
}
