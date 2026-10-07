import AppKit

// AnnotationCanvasView のテキスト入力（入力欄を重ねる・確定する）。

extension AnnotationCanvasView {

    // MARK: テキスト入力

    /// 入力欄を重ねてテキストの入力（既存なら編集）を始める。
    /// - Parameters:
    ///   - origin: 文字の左上（注釈座標）。
    ///   - existing: 編集する既存のテキスト注釈。新規なら nil。
    func beginTextEditing(at origin: CGPoint, existing: Annotation?) {
        commitTextEditing()
        stylePopover.close()

        let view = AnnotationTextView()
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        // 折り返さない（枠で折り返さない仕様。改行は Return で入れる）。
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        // 画像に載せる文字なので、勝手な置換・補正は止める。
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.wantsLayer = true
        view.layer?.cornerRadius = 3
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.string = existing?.text ?? ""

        view.onCommit = { [weak self] in self?.commitTextEditing() }
        view.onTextChange = { [weak self] in self?.layoutTextEditor() }
        view.onResign = { [weak self, weak view] in
            // 外のクリック・Tab などでフォーカスが移った。確定する。
            // resign の最中にビューを外さないよう、1 周遅らせる。
            Task { @MainActor in
                guard let self, let view, self.textSession?.view === view,
                    self.window?.firstResponder !== view
                else { return }
                self.commitTextEditing()
            }
        }

        textSession = TextSession(view: view, original: existing, origin: origin)
        addSubview(view)
        applyTextEditorFont()
        layoutTextEditor()
        editor.isEditingText = true

        if let existing {
            document.select([existing.id])
        } else {
            document.clearSelection()
        }
        window?.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        invalidate()
    }

    /// 編集中のスタイル（既存なら注釈のスタイル、新規ならテキストの最後のスタイル）。
    private var editingTextStyle: TextStyle? {
        guard let session = textSession else { return nil }
        return (session.original?.style ?? editor.style(for: .text)).text
    }

    /// 入力欄のフォント・色を、スタイルと表示倍率に合わせる。
    /// 入力のたびには呼ばない（変換中の文字の属性を乱さないため）。
    func applyTextEditorFont() {
        guard let session = textSession, var style = editingTextStyle else { return }
        style.size *= Double(viewScale)
        let view = session.view
        view.font = AnnotationTextLayout.font(for: style) as NSFont
        view.textColor = style.color.nsColor
        view.insertionPointColor = style.color.nsColor
        view.backgroundColor = TextEditingAppearance.cushionColor(for: style.color)
    }

    /// 入力欄の位置と大きさ。レンダラと同じ測り方（AnnotationTextLayout）で合わせる。
    func layoutTextEditor() {
        guard let session = textSession, var style = editingTextStyle else { return }
        let scale = viewScale
        style.size *= Double(scale)
        let size = AnnotationTextLayout.size(of: session.view.string, style: style)
        session.view.frame = CGRect(
            x: session.origin.x * scale, y: session.origin.y * scale,
            width: size.width + TextEditingAppearance.widthPadding, height: size.height)
    }

    /// 入力を確定する。空なら作らず（既存を空にしたら削除）、確定は取り消し 1 回分。
    func commitTextEditing() {
        guard let session = textSession else { return }
        // 先に状態を外す（ビューを外すときの resign から再入しないため）。
        textSession = nil
        editor.isEditingText = false

        let view = session.view
        view.onCommit = nil
        view.onTextChange = nil
        view.onResign = nil
        // 日本語変換の途中なら、いまの変換結果をそのまま確定させる
        // （破棄すると入力途中の文字が消える）。
        if view.hasMarkedText() {
            view.unmarkText()
            view.inputContext?.discardMarkedText()
        }
        let text = view.string
        let hadFocus = window?.firstResponder === view
        view.removeFromSuperview()
        if hadFocus { window?.makeFirstResponder(self) }

        switch AnnotationTextEditing.outcome(original: session.original, editedText: text) {
        case .none:
            break
        case .create(let text):
            let annotation = Annotation(
                kind: .text, start: session.origin, end: session.origin, text: text,
                style: editor.style(for: .text))
            document.add(annotation, select: true)
        case .update(let text):
            if let id = session.original?.id {
                document.mutate(ids: [id]) { $0.text = text }
                document.select([id])
            }
        case .delete:
            if let id = session.original?.id { document.remove(ids: [id]) }
        }
        invalidate()
    }
}
