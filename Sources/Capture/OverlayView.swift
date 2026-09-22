import AppKit

// 範囲選択の描画を担うビュー（要求 4.2）。
//
// - 全体を暗いオーバーレイで覆う
// - 選択範囲の内側は暗転を解除して元の画面を見せる
// - 選択範囲の寸法（幅 × 高さ px）をカーソル近傍に表示する
// - カーソルは十字（レティクル）
final class OverlayView: NSView {

    /// カーソル下のウィンドウのハイライト情報（このビューのローカル座標）。
    struct WindowHighlight: Equatable {
        /// ウィンドウ全体の枠。隠れている部分も含む。
        var frame: CGRect
        /// 画面で実際に見えている領域。重なりを差し引いた矩形群。
        var visibleRects: [CGRect]
        /// 「アプリ名 — ウィンドウタイトル」。空ならラベルを描かない。
        ///
        /// ウィンドウが画面をまたぐと同じハイライトが複数のオーバーレイに
        /// 配られる。ラベルを出すのは 1 枚だけにしたいので、それ以外には
        /// 空を入れて配る（SelectionCoordinator が決める）。
        var label: String
    }

    /// 選択中の矩形（このビューのローカル座標）。nil なら未選択。
    var selectionRect: CGRect? {
        didSet {
            guard selectionRect != oldValue else { return }
            needsDisplay = true
        }
    }

    /// カーソル下のウィンドウ（このビューのローカル座標）。nil なら該当なし。
    ///
    /// クリックでウィンドウをキャプチャできること（CAP-06）を事前に伝えるため、
    /// ドラッグ開始前だけハイライトする。ドラッグ中は範囲選択に集中させたいので
    /// SelectionCoordinator 側で nil にする。
    var hoveredWindow: WindowHighlight? {
        didSet {
            guard hoveredWindow != oldValue else { return }
            needsDisplay = true
        }
    }

    /// このビューが載っているスクリーンの倍率。寸法をピクセルで出すのに使う。
    /// 非 Retina 環境もあるため既定は 1.0（等倍）とし、嘘の寸法を出さない。
    var backingScale: CGFloat = 1.0

    /// マウス操作の通知。座標はすべて AppKit のグローバル座標で渡す。
    ///
    /// イベントをローカルモニタではなくビューで受けるのは、モニタが
    /// 「自アプリがアクティブ」を前提とするため起動直後のクリックを
    /// 取り逃す危険があるため。ドラッグは最初に mouseDown したビューが
    /// 掴み続けるので、グローバル座標に直せば画面をまたいでも分断しない。
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?
    /// カーソル移動の通知。ウィンドウ枠のハイライト更新に使う（CAP-06）。
    var onMouseMoved: ((CGPoint) -> Void)?

    override var isOpaque: Bool { false }

    // MARK: - マウスイベント

    override func mouseDown(with event: NSEvent) {
        NSCursor.crosshair.set()
        onMouseDown?(NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        // ドラッグ中も十字を維持する（他のカーソルに戻されることがある）。
        NSCursor.crosshair.set()
        onMouseDragged?(NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        onMouseUp?(NSEvent.mouseLocation)
    }

    // MARK: - カーソル

    // レティクル（十字）カーソル。要求 4.2。
    //
    // borderless で level が高いオーバーレイウィンドウでは
    // addCursorRect / cursorUpdate だけでは反映が不安定で、
    // 「なったりならなかったり」する。そのため
    // NSCursor.set() を明示的に呼ぶ経路を複数用意して確実にする。

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        onMouseMoved?(NSEvent.mouseLocation)
    }

    /// マウス追跡領域を張り直す。ウィンドウのリサイズや表示直後に呼ばれる。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    // MARK: - 描画

    override func draw(_ dirtyRect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 暗転はしない（ユーザー選択）。元の画面をそのまま見せることで
        // 「何を撮るか」を判断しやすくする。オーバーレイの存在は
        // レティクルカーソルと選択枠で示す。
        //
        // ただし完全な透明だとマウスイベントが下のウィンドウへ抜けるため、
        // ほぼ不可視のごく薄い塗りを敷いてヒットテストを成立させる。
        context.setFillColor(NSColor.black.withAlphaComponent(0.005).cgColor)
        context.fill(bounds)

        guard let selection = selectionRect, selection.width > 0, selection.height > 0 else {
            // 範囲選択が始まっていないときだけウィンドウ枠を示す（CAP-06）。
            drawHoveredWindowHighlight(in: context)
            return
        }

        // 選択範囲の枠線。暗転がないぶん、明暗どちらの背景でも見えるように
        // 白の実線と黒の細い外周を重ねてコントラストを確保する。
        let rect = selection.insetBy(dx: 0.5, dy: 0.5)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        context.setLineWidth(3.0)
        context.stroke(rect)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.0)
        context.stroke(rect)

        drawDimensionLabel(for: selection, in: context)
    }

    /// カーソル下のウィンドウをハイライトする（CAP-06）。
    ///
    /// 「クリックすればこのウィンドウが撮れる」ことを事前に見せるのが目的。
    /// 選択枠（白の実線 + 黒の縁取り）とは意図的に見た目を変えてある。
    /// 同じ描き方にすると、確定した選択とこれから起きうる候補の区別が
    /// つかなくなる。青系の塗りと破線でシステムの選択表現に寄せる。
    ///
    /// ★塗るのは「実際に見えている領域」だけにする。
    /// ウィンドウ全体の枠を塗ると、手前のウィンドウに隠れている部分まで
    /// 青くなり、ユーザーが見ている重なりと食い違う。
    private func drawHoveredWindowHighlight(in context: CGContext) {
        guard let highlight = hoveredWindow else { return }

        // 画面外まで伸びる領域を描いても無駄なので可視範囲に切る。
        let rects = highlight.visibleRects
            .map { $0.intersection(bounds) }
            .filter { !$0.isNull && !$0.isEmpty }
        guard !rects.isEmpty else { return }

        context.saveGState()
        // 見えている領域の外には一切描かない。塗りも枠線もここで形が決まる。
        context.clip(to: rects)

        context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor)
        context.fill(bounds)

        // ウィンドウの輪郭を引く。クリップされるので、見えている部分の
        // 枠だけが残る。線の外半分はクリップで削られるため太めに引く。
        context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(4.0)
        context.setLineDash(phase: 0, lengths: [6, 4])
        context.stroke(highlight.frame.insetBy(dx: 1, dy: 1))

        context.restoreGState()

        drawWindowLabel(highlight.label, anchoredIn: rects, in: context)
    }

    /// ハイライト中のウィンドウの名前を見えている領域の中に描く。
    ///
    /// 同じ位置・同じ大きさのウィンドウが重なっていると枠の形だけでは
    /// どれが撮れるのか判別できないため、名前で確定させる。
    private func drawWindowLabel(_ label: String, anchoredIn rects: [CGRect], in context: CGContext) {
        guard !label.isEmpty else { return }

        let padding: CGFloat = 6
        let inset: CGFloat = 8
        // 幅の上限。ウィンドウが広いときにタイトルが画面いっぱいに伸びるのを防ぐ。
        let maximumTextWidth: CGFloat = 420
        // これ以下だと数文字しか出ず、かえって紛らわしい。
        let minimumTextWidth: CGFloat = 60

        // 長いタイトルは末尾を省略する（VSCode のように「作業内容 — プロジェクト名」
        // と続く長大なタイトルがある）。
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let string = NSAttributedString(string: label, attributes: attributes)
        let naturalSize = string.size()
        let boxHeight = naturalSize.height + padding

        // 箱が丸ごと収まる可視矩形の中から、最も広いものを選ぶ。
        //
        // 単純に最大面積の矩形を選ぶと、それが細い帯だったときに
        // 「入らないので描かない」で終わってしまう。さらに悪いことに、
        // 高さを見ないと箱が可視領域の外（＝手前のウィンドウの上）へ
        // はみ出す。ラベルはクリップの外で描くので誰も止めてくれない。
        let required = CGSize(
            width: minimumTextWidth + padding * 2 + inset * 2,
            height: boxHeight + inset * 2
        )
        let fitting = rects.filter { $0.width >= required.width && $0.height >= required.height }
        guard let anchor = fitting.max(by: { $0.width * $0.height < $1.width * $1.height })
        else { return }

        let textWidth = min(naturalSize.width, anchor.width - (padding + inset) * 2, maximumTextWidth)
        let boxSize = CGSize(width: textWidth + padding * 2, height: boxHeight)

        // 可視領域の左上に置く。ウィンドウのタイトルバーがある側なので、
        // 内容の邪魔になりにくい。
        let origin = CGPoint(
            x: anchor.minX + inset,
            y: anchor.maxY - boxSize.height - inset
        )
        let box = CGRect(origin: origin, size: boxSize)

        context.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        context.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.fillPath()

        string.draw(
            in: CGRect(
                x: box.minX + padding,
                y: box.minY + padding / 2,
                width: textWidth,
                height: naturalSize.height
            )
        )
    }

    /// 寸法（幅 × 高さ px）をカーソル近傍に描く。
    private func drawDimensionLabel(for selection: CGRect, in context: CGContext) {
        // ポイント → ピクセルに換算して表示する。Retina では実解像度が
        // ポイントの backingScale 倍になるため、撮れる画像の実寸を出す。
        let pixelWidth = Int((selection.width * backingScale).rounded())
        let pixelHeight = Int((selection.height * backingScale).rounded())
        let text = "\(pixelWidth) × \(pixelHeight)"

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()

        let padding: CGFloat = 6
        let boxSize = CGSize(width: textSize.width + padding * 2, height: textSize.height + padding)

        // 既定では選択範囲の下に置き、画面外に出るなら上に逃がす。
        var origin = CGPoint(
            x: selection.midX - boxSize.width / 2,
            y: selection.minY - boxSize.height - 8
        )
        if origin.y < bounds.minY {
            origin.y = selection.maxY + 8
        }
        origin.x = max(bounds.minX + 4, min(origin.x, bounds.maxX - boxSize.width - 4))

        let box = CGRect(origin: origin, size: boxSize)

        context.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        let path = CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.addPath(path)
        context.fillPath()

        string.draw(at: CGPoint(x: box.minX + padding, y: box.minY + padding / 2))
    }
}
