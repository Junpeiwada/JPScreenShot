import AppKit

// AnnotationCanvasView のマウス操作（押す・ドラッグ・離す）。

extension AnnotationCanvasView {

    // MARK: マウス

    /// イベントのマウス位置（注釈座標）。
    func annotationPoint(of event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return AnnotationInteraction.annotationPoint(fromView: local, scale: viewScale)
    }

    /// 現在のツールの種類（押したときの判定の切り替え）。
    var pressMode: AnnotationInteraction.PressMode {
        switch editor.tool {
        case .select: .select
        case .text: .text
        default: .shape
        }
    }

    /// 押した位置の対象。カーソルと mouseDown が同じ引数で呼ぶ。
    /// `mode` を省略すると現在のツールの判定（右クリックだけは `.select` を渡す）。
    func pressTarget(
        at point: CGPoint, mode: AnnotationInteraction.PressMode? = nil
    ) -> AnnotationInteraction.PressTarget {
        AnnotationInteraction.pressTarget(
            annotations: document.annotations, selectedIDs: document.selectedIDs,
            at: point, scale: viewScale, mode: mode ?? pressMode)
    }

    override func mouseDown(with event: NSEvent) {
        // ポップオーバーは押した時点では閉じない。ドラッグ（描く・動かす・変形・範囲選択）が
        // 実際に始まったら閉じる（mouseDragged）。選択中を動かさずにクリックしただけなら、
        // 開いたまま位置を合わせ直す（mouseUp）。
        opensPopoverOnRelease = false
        // 入力中のテキストは、外をクリックしたら確定する。先に確定しておかないと、
        // このあとの当たり判定が確定前の注釈の配列で行われてしまう。
        commitTextEditing()
        // キャンバスをクリックしたらキーボード（⌫・⌘Z）の宛先にする。
        window?.makeFirstResponder(self)

        // Control クリックは右クリックと同じ（ポップオーバー）。
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }

        let point = annotationPoint(of: event)
        let shift = event.modifierFlags.contains(.shift)
        hasBegunChange = false
        draft = nil
        marqueeRect = nil

        let target = pressTarget(at: point)

        // テキストのダブルクリックは、ツールによらず編集の再開。
        // （ハンドル上のダブルクリックは変形を優先する。）
        if event.clickCount >= 2,
            let id = AnnotationInteraction.textToEditOnDoubleClick(
                annotations: document.annotations, selectedIDs: document.selectedIDs,
                at: point, scale: viewScale),
            let text = document.annotation(id: id)
        {
            interaction = .idle
            beginTextEditing(at: text.start, existing: text)
            return
        }

        // カーソルと同じ関数（pressAction）で「押したら何が起きるか」を決める。
        switch AnnotationInteraction.pressAction(for: target, mode: pressMode, shift: shift) {
        case .resize(let handle, let id):
            // ツールによらずハンドルが最優先。
            if let original = document.annotation(id: id) {
                let center = dragStart(for: original, handle: handle)
                interaction = .resize(
                    original: original, handle: handle, start: point,
                    grabOffset: CGSize(width: point.x - center.x, height: point.y - center.y))
            }

        case .moveSelected(let id):
            pressSelectedBody(id: id, point: point)

        case .toggleSelection(let id):
            pressObjectWithSelectTool(id: id, point: point, shift: true)

        case .nothing:
            interaction = .idle

        case .pickObject(let id):
            // 選択ツール・描画ツールとも、押したものを選ぶ（ドラッグなら選んでそのまま移動）。
            pressObjectWithSelectTool(id: id, point: point, shift: shift)

        case .textOnObject(let id):
            // テキストツールで既存のテキストを押したら、新規ではなく編集にする。
            // テキスト以外の上なら、その位置に新しいテキストを置く。
            interaction = .idle
            if let text = document.annotation(id: id), text.kind == .text {
                beginTextEditing(at: text.start, existing: text)
            } else {
                beginTextEditing(at: point, existing: nil)
            }

        case .placeText:
            interaction = .idle
            beginTextEditing(at: point, existing: nil)

        case .create:
            if let kind = editor.tool.kind {
                interaction = .create(kind: kind, anchor: point, shift: shift)
            }

        case .marquee:
            // 選択ツール。Shift なしなら選択を外してから範囲選択を始める。
            let base = shift ? document.selectedIDs : []
            if !shift { document.clearSelection() }
            interaction = .marquee(start: point, additive: shift, base: base)
        }
        updateCursorForCurrentInteraction()
    }

    /// 選択中のものの本体・選択枠の辺の近くを押したとき。ツールによらず移動を始める
    /// （複数選択なら全部まとめて）。
    ///
    /// - Shift 付きは追加／解除になる（`pressAction` の `.toggleSelection`）ので、ここには来ない。
    /// - テキストツールは、動かさずに離したら従来どおり編集（既存テキスト）／新規テキスト、
    ///   ドラッグしたら移動にする。
    private func pressSelectedBody(id: UUID, point: CGPoint) {
        var clickAction: ClickAction?
        if editor.tool == .text {
            if let text = document.annotation(id: id), text.kind == .text {
                clickAction = .editText(text)
            } else {
                clickAction = .newText(at: point)
            }
        }
        // 複数選択の 1 件を動かさずにクリックしたら、その 1 件に絞る（選択ツールと同じ）。
        let collapseTo: UUID? = document.selectedIDs.count > 1 ? id : nil
        interaction = .move(
            origins: document.selectedAnnotations, start: point, collapseTo: collapseTo,
            clickAction: clickAction)
    }

    /// 選択ツールでオブジェクトを押したとき。
    private func pressObjectWithSelectTool(id: UUID, point: CGPoint, shift: Bool) {
        if shift {
            // Shift クリックは追加／解除だけ。ドラッグでの移動は始めない。
            // 離したとき、選択が残っていれば小窓を開く。
            document.toggleSelection(id)
            opensPopoverOnRelease = true
            interaction = .idle
            return
        }
        var collapseTo: UUID?
        if document.selectedIDs.contains(id) {
            // すでに選択中なら選択は保ったまま（複数選択をまとめて動かせるように）。
            // 動かさずに離したときだけ、その 1 件に絞る。
            if document.selectedIDs.count > 1 { collapseTo = id }
        } else {
            document.select([id])
        }
        interaction = .move(
            origins: document.selectedAnnotations, start: point, collapseTo: collapseTo,
            clickAction: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = annotationPoint(of: event)
        let shift = event.modifierFlags.contains(.shift)
        let scale = viewScale

        switch interaction {
        case .idle:
            break

        case .create(let kind, let anchor, _):
            if draft == nil,
                !AnnotationInteraction.isLargeEnoughToCreate(from: anchor, to: point, scale: scale)
            {
                return
            }
            draft = AnnotationInteraction.makeAnnotation(
                kind: kind, from: anchor, to: point, constrain: shift,
                style: editor.style(for: kind), id: draft?.id ?? UUID())
            stylePopover.close()
            invalidate()

        case .move(let origins, let start, _, _):
            guard beginChangeIfDraggedFarEnough(from: start, to: point) else { return }
            stylePopover.close()
            let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
            for origin in origins {
                document.setWithoutHistory(AnnotationGeometry.moved(origin, by: delta))
            }

        case .resize(let original, let handle, let start, let grabOffset):
            // 押した位置から測る閾値（移動と同じ）。クリックだけでは形が変わらない。
            guard beginChangeIfDraggedFarEnough(from: start, to: point) else { return }
            stylePopover.close()
            let target = CGPoint(x: point.x - grabOffset.width, y: point.y - grabOffset.height)
            document.setWithoutHistory(
                AnnotationGeometry.resized(original, handle: handle, to: target, constrain: shift))

        case .marquee(let start, let additive, let base):
            stylePopover.close()
            let rect = AnnotationGeometry.rect(from: start, to: point)
            marqueeRect = rect
            var ids = AnnotationInteraction.marqueeSelection(in: document.annotations, rect: rect)
            if additive { ids.formUnion(base) }
            document.select(ids)
            invalidate()
        }
        updateCursorForCurrentInteraction()
    }

    /// ハンドルの中心。
    private func dragStart(for original: Annotation, handle: AnnotationGeometry.Handle) -> CGPoint {
        AnnotationGeometry.handles(of: original).first { $0.handle == handle }?.point
            ?? original.start
    }

    /// 閾値を超えたら取り消し履歴を 1 回だけ積み、以後 true を返す。
    private func beginChangeIfDraggedFarEnough(from start: CGPoint, to point: CGPoint) -> Bool {
        if hasBegunChange { return true }
        guard AnnotationInteraction.isLargeEnoughToCreate(from: start, to: point, scale: viewScale)
        else { return false }
        document.beginChange()
        hasBegunChange = true
        return true
    }

    override func mouseUp(with event: NSEvent) {
        // クリックで選択したとき（ドラッグなし・選択が 1 件以上）だけ小窓を自動で開く。
        // 描き終えた直後・移動や変形の直後・範囲選択の直後は開かない。
        var opensPopover = opensPopoverOnRelease
        opensPopoverOnRelease = false
        defer {
            interaction = .idle
            hasBegunChange = false
            draft = nil
            marqueeRect = nil
            invalidate()
            // 小さく戻して破棄した作成中のぼかしなど、使わなくなったキャッシュを解放する。
            pruneRedactionCache()
            refreshCursor(atWindowPoint: event.locationInWindow)
            if opensPopover, !document.selectedIDs.isEmpty, textSession == nil {
                if stylePopover.isShown {
                    // 開いたままなら閉じ直さず、位置だけ合わせ直す。
                    repositionStylePopover()
                } else {
                    showStylePopover()
                }
            }
        }

        switch interaction {
        case .idle:
            break

        case .create(_, _, let shift):
            if let draft {
                // 確定。離した位置でも十分な大きさのときだけ作る。
                if AnnotationInteraction.isLargeEnoughToCreate(
                    from: draft.start, to: draft.end, scale: viewScale)
                {
                    document.add(draft, select: true)
                }
            } else {
                // ドラッグしなかった = クリック。何もない所なので選択を外す。
                if !shift { document.clearSelection() }
            }

        case .move(_, _, let collapseTo, let clickAction):
            if hasBegunChange {
                document.commitChange()
                // 動かし終えたら小窓を開く（未選択から直接ドラッグした場合も）。
                opensPopover = AnnotationInteraction.opensPopover(
                    after: .moved, selectionCount: document.selectedIDs.count)
            } else if let clickAction {
                // テキストツール: 動かさずに離した。編集（新規含む）を始める。
                switch clickAction {
                case .editText(let text): beginTextEditing(at: text.start, existing: text)
                case .newText(let point): beginTextEditing(at: point, existing: nil)
                }
            } else {
                if let collapseTo { document.select([collapseTo]) }
                opensPopover = AnnotationInteraction.opensPopover(
                    after: .clicked, selectionCount: document.selectedIDs.count)
            }

        case .resize:
            if hasBegunChange {
                document.commitChange()
                opensPopover = AnnotationInteraction.opensPopover(
                    after: .resized, selectionCount: document.selectedIDs.count)
            }

        case .marquee:
            break
        }
    }
}
