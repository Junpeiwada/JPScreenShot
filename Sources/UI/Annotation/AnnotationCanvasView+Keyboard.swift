import AppKit

// AnnotationCanvasView のキー操作・フォーカス・取り消し/やり直し/複製。

extension AnnotationCanvasView {

    // MARK: キーボード

    override func keyDown(with event: NSEvent) {
        // テキスト入力中は入力欄が first responder なのでここへは来ないが、念のため。
        guard !editor.isEditingText,
            let command = AnnotationKeyboard.command(
                keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                modifiers: event.modifierFlags)
        else {
            super.keyDown(with: event)
            return
        }

        switch command {
        case .delete:
            guard !document.selectedIDs.isEmpty else { return }
            document.remove()

        case .selectTool(let tool):
            if !event.isARepeat { editor.selectTool(tool) }

        case .nudge(let dx, let dy):
            nudgeSelection(by: CGSize(width: dx, height: dy), isRepeat: event.isARepeat)

        case .escape:
            if !document.selectedIDs.isEmpty {
                stylePopover.close()
                document.clearSelection()
            } else {
                // 選択が無ければ閉じる。通常は「閉じる」ボタンの .cancelAction が先に
                // 受けるのでここへは来ないが、受け損ねたときの保険。
                super.keyDown(with: event)
            }
        }
    }

    /// 選択中を動かす。キーを押し続けた一連（自動リピート）は取り消し 1 回にまとめる。
    private func nudgeSelection(by delta: CGSize, isRepeat: Bool) {
        let ids = document.selectedIDs
        guard !ids.isEmpty else { return }
        let move: (inout Annotation) -> Void = { $0 = AnnotationGeometry.moved($0, by: delta) }
        if isRepeat, let count = nudgeUndoCount, count == document.undoStack.count {
            document.mutateWithoutHistory(ids: ids, move)
        } else {
            document.mutate(ids: ids, move)
            nudgeUndoCount = document.undoStack.count
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { editor.isCanvasFocused = true }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            editor.isCanvasFocused = false
            nudgeUndoCount = nil
        }
        return resigned
    }

    /// ⌘I で詳しいスタイル設定を開く。キャンバスにフォーカスがあるときだけ
    /// （OCR テキスト欄の ⌘I を奪わない）。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, modifiers == .command,
            event.charactersIgnoringModifiers?.lowercased() == "i"
        {
            if stylePopover.isShown {
                stylePopover.close()
            } else if !document.selectedIDs.isEmpty {
                showStylePopover()
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: 取り消し・やり直し（メインメニューから First Responder へ届く）

    // SwiftUI の .keyboardShortcut("z") は使わない。OCR テキスト欄の ⌘Z を奪うため。
    // メインメニューの「取り消す」「やり直す」は target が nil なので、
    // First Responder がキャンバスのときだけここに届く。

    @objc func undo(_ sender: Any?) {
        document.undo()
    }

    @objc func redo(_ sender: Any?) {
        document.redo()
    }

    /// ⌘D。メインメニュー「編集 > 複製」から First Responder に届く。
    /// OCR テキスト欄は `duplicate:` に応答しないので、そちらでは自動で無効になる。
    @objc func duplicate(_ sender: Any?) {
        guard !document.selectedIDs.isEmpty else { return }
        document.duplicate()
        nudgeUndoCount = nil
    }
}
