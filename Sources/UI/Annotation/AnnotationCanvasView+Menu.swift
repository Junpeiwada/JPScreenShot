import AppKit

// AnnotationCanvasView の右クリックメニュー・スタイルの小窓。

extension AnnotationCanvasView {

    // MARK: スタイルのポップオーバー

    /// 右クリック（Control クリックも）。注釈の上なら選択して、標準のコンテキストメニューを出す。
    /// 何もない所では出さない。スタイルの詳細は項目「スタイル…」から小窓で開く。
    override func rightMouseDown(with event: NSEvent) {
        stylePopover.close()
        commitTextEditing()
        window?.makeFirstResponder(self)

        let point = annotationPoint(of: event)
        switch pressTarget(at: point, mode: .select) {
        case .handle:
            break  // すでに選択中
        case .selectedBody:
            break  // すでに選択中
        case .object(let id):
            if !document.selectedIDs.contains(id) { document.select([id]) }
        case .none:
            return
        }
        guard !document.selectedIDs.isEmpty else { return }
        NSMenu.popUpContextMenu(makeContextMenu(), with: event, for: self)
    }

    /// 右クリックのメニュー。ショートカットは表示だけ（実際のキーは別経路で効く）。
    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = true

        func add(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = []) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            menu.addItem(item)
        }
        add("スタイル…", #selector(showStyleFromMenu(_:)), key: "i", modifiers: .command)
        menu.addItem(.separator())
        add("複製", #selector(duplicate(_:)), key: "d", modifiers: .command)
        add("前面へ", #selector(bringSelectionToFront(_:)))
        add("背面へ", #selector(sendSelectionToBack(_:)))
        menu.addItem(.separator())
        add("削除", #selector(deleteSelection(_:)), key: "\u{8}")
        return menu
    }

    @objc private func showStyleFromMenu(_ sender: Any?) { showStylePopover() }

    @objc private func bringSelectionToFront(_ sender: Any?) {
        guard !document.selectedIDs.isEmpty else { return }
        document.bringToFront()
    }

    @objc private func sendSelectionToBack(_ sender: Any?) {
        guard !document.selectedIDs.isEmpty else { return }
        document.sendToBack()
    }

    @objc private func deleteSelection(_ sender: Any?) {
        guard !document.selectedIDs.isEmpty else { return }
        document.remove()
    }

    /// 選択中の外接矩形（ビュー座標）の位置にポップオーバーを出す。
    func showStylePopover() {
        guard let rect = stylePopoverRect() else { return }
        stylePopover.show(editor: editor, relativeTo: rect, of: self)
    }

    /// 開いている小窓の指す範囲を、いまの選択に合わせ直す。
    func repositionStylePopover() {
        if let rect = stylePopoverRect() { stylePopover.reposition(to: rect) }
    }

    /// ポップオーバーが指す範囲（ビュー座標）。選択が空なら nil。
    func stylePopoverRect() -> NSRect? {
        let selected = document.selectedAnnotations
        guard let first = selected.first else { return nil }
        let scale = viewScale
        let union = selected.dropFirst().reduce(AnnotationGeometry.bounds(of: first)) {
            $0.union(AnnotationGeometry.bounds(of: $1))
        }
        var rect = union.scaled(by: scale).insetBy(dx: -2, dy: -2)
        // スクロールで一部しか見えていないとき、見えている部分に合わせる
        // （画面外の位置を指すと、ポップオーバーが離れた場所に出る）。
        let visible = visibleRect
        rect = rect.intersection(visible)
        if rect.isNull || rect.isEmpty { rect = visible }
        return rect
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(duplicate(_:)), #selector(showStyleFromMenu(_:)),
            #selector(bringSelectionToFront(_:)), #selector(sendSelectionToBack(_:)),
            #selector(deleteSelection(_:)):
            !document.selectedIDs.isEmpty
        case #selector(undo(_:)): document.canUndo
        case #selector(redo(_:)): document.canRedo
        default: true
        }
    }
}
