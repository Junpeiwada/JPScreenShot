import AppKit

// AnnotationCanvasView の描画（注釈・選択枠・ハンドル）。

extension AnnotationCanvasView {

    /// 注釈と選択枠を描く（`AnnotationOverlayView.draw` から呼ばれる）。
    /// 元画像は `baseView` のレイヤーが出すので、ここでは描かない。
    func drawContent(in context: CGContext) {
        let scale = viewScale

        // 注釈。ここから「注釈座標（ポイント・y 下向き）」。書き出しと同じ描画関数を通す。
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.interpolationQuality = .high
        var annotations = document.annotations
        if let draft { annotations.append(draft) }
        // 編集中の既存テキストは隠す（重ねた入力欄が同じ位置に出ているため）。
        let hiding: Set<UUID> = textSession?.original.map { [$0.id] } ?? []
        AnnotationRenderer.draw(annotations, using: editor.redaction, in: context, hiding: hiding)
        context.restoreGState()

        // 選択枠・ハンドル・範囲選択は画面上で一定の大きさにするため、倍率を掛けずに
        // ビュー座標で描く。書き出しには含まれない。
        drawSelectionOverlay(in: context, scale: scale)
    }

    private func drawSelectionOverlay(in context: CGContext, scale: CGFloat) {
        // アクセントカラー（テキスト入力欄の枠と同じ）。システム設定の変更に追従する。
        let blue = NSColor.controlAccentColor.cgColor
        let selected = document.selectedAnnotations
        let single = selected.count == 1

        let editingID = textSession?.original?.id
        for annotation in selected where annotation.id != editingID {
            // 選択枠。移動の当たり判定（AnnotationInteraction.selectionFrame）と同じ矩形。
            let rect = AnnotationInteraction.selectionFrame(of: annotation).scaled(by: scale)
            strokeDashedRect(rect, in: context, color: blue)
            // 線・矢印は両端のハンドルだけ。複数選択のときは変形できないので
            // 端点の印として出す（つかめるのは 1 件だけ選んでいるときだけ）。
            if single || annotation.kind.isLinear {
                for position in AnnotationGeometry.handles(of: annotation) {
                    let center = CGPoint(x: position.point.x * scale, y: position.point.y * scale)
                    drawHandle(
                        at: center,
                        round: position.handle == .start || position.handle == .end,
                        in: context, color: blue)
                }
            }
        }

        if let marqueeRect {
            let rect = marqueeRect.scaled(by: scale)
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
            context.fill(rect)
            strokeDashedRect(rect, in: context, color: blue)
        }
    }

    /// 白の下線を敷いた破線の矩形。明るい背景でも暗い背景でも見えるようにする。
    private func strokeDashedRect(_ rect: CGRect, in context: CGContext, color: CGColor) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineWidth(1)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        context.stroke(rect)
        context.setStrokeColor(color)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(rect)
    }

    /// 白い塗り＋青い枠のハンドル。矩形は四角、線・矢印の端点は丸。
    private func drawHandle(at center: CGPoint, round: Bool, in context: CGContext, color: CGColor) {
        let size = AnnotationInteraction.handleSize
        let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setStrokeColor(color)
        context.setLineWidth(1.5)
        if round {
            context.fillEllipse(in: rect)
            context.strokeEllipse(in: rect)
        } else {
            context.fill(rect)
            context.stroke(rect)
        }
    }

}
