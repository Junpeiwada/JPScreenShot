import AppKit
import SwiftUI

// 選択中の注釈の詳しいスタイル設定（画面構成案 5 章）。NSPopover の中身を SwiftUI で作る。
//
// 色と太さはレール（ToolRail）で足りるので、ここは「それ以外」を変えたいときだけ開く。
// 選択中に ⌘I または右クリックで開き、選択の外接矩形の上側（入らなければ AppKit が
// 反対側へ寄せる）に出す。ドラッグを始めたら閉じる（キャンバス側）。

// MARK: - コントローラ

@MainActor
final class StylePopoverController: NSObject, NSPopoverDelegate {

    private var popover: NSPopover?
    /// スライダーの「離した」通知が届かないまま閉じても連続操作が固まらないよう、
    /// 閉じたときに終わらせるために覚えておく。
    private weak var editor: AnnotationEditor?

    var isShown: Bool { popover?.isShown ?? false }

    /// - Parameters:
    ///   - rect: 指し示す範囲（`view` の座標）。選択の外接矩形。
    ///   - view: キャンバス。
    func show(editor: AnnotationEditor, relativeTo rect: NSRect, of view: NSView) {
        close()
        self.editor = editor

        let popover = NSPopover()
        // 自動で開くので、キャンバスのクリック・ドラッグ・キー操作の邪魔をしない
        // （.transient だと外クリックで閉じる処理が割り込む）。閉じるのはキャンバス側
        // （ドラッグ開始・選択解除・Esc）と、ウィンドウを閉じる／隠すとき。
        popover.behavior = .semitransient
        popover.delegate = self
        let host = NSHostingController(
            rootView: StylePopoverContent(editor: editor) { [weak self] in self?.close() })
        // 中身の大きさ（種類で変わる）にポップオーバーを合わせる。
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        self.popover = popover

        // 上側に出す。**flipped なビューでは y の小さい側が上**なので、`.minY` を指定する
        // （非 flipped なら `.maxY`）。入りきらなければ AppKit が反対側へ移す。
        let edge: NSRectEdge = view.isFlipped ? .minY : .maxY
        popover.show(relativeTo: rect, of: view, preferredEdge: edge)

        // ポップオーバーがキーウィンドウを奪うと、⌫・矢印・Esc・ツールキーが
        // キャンバスに届かない。奪われていたら返す（中のテキスト欄をクリックすれば
        // そのときだけポップオーバーがキーになる）。
        if let window = view.window {
            DispatchQueue.main.async { [weak window] in
                guard let window, !window.isKeyWindow else { return }
                window.makeKey()
            }
        }
    }

    /// 開いたまま、指す範囲だけ動かす（選択が変わったとき）。
    func reposition(to rect: NSRect) {
        guard let popover, popover.isShown else { return }
        popover.positioningRect = rect
    }

    func close() {
        popover?.close()
        popover = nil
        editor?.endContinuousStyleChange()
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        editor?.endContinuousStyleChange()
    }
}

// MARK: - 中身

/// ポップオーバーの中身。選択中の注釈の種類で出す項目が変わる。
/// 選択が空になったら（取り消しなど）閉じる。
struct StylePopoverContent: View {
    let editor: AnnotationEditor
    let onEmpty: () -> Void

    private var selected: [Annotation] { editor.document.selectedAnnotations }

    var body: some View {
        // 項目名の列（右揃え・固定幅）とコントロールの列（左端を揃える）の Grid。
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
            if selected.count > 1 {
                CommonStyleSection(editor: editor)
            } else if let annotation = selected.first {
                switch annotation.kind {
                case .arrow, .line, .rect, .ellipse:
                    FigureStyleSection(editor: editor, kind: annotation.kind)
                case .text:
                    TextStyleSection(editor: editor)
                case .blur, .mosaic:
                    RedactionStyleSection(editor: editor, kind: annotation.kind)
                }
            } else {
                Text("選択中の注釈がありません")
                    .foregroundStyle(.secondary)
            }

            if !selected.isEmpty {
                Divider()
                arrangeButtons
            }
        }
        .padding(16)
        .frame(width: 340)
        .onChange(of: selected.isEmpty) { _, isEmpty in
            if isEmpty { onEmpty() }
        }
        // 選択が変わったら、スライダーの連続操作は終わったものとする。
        .onChange(of: editor.document.selectedIDs) { _, _ in
            editor.selectionDidChange()
        }
    }

    /// 重なり順と削除（要求 ANN-05）。重なり順は同じ層の中だけで動く。
    private var arrangeButtons: some View {
        HStack(spacing: 8) {
            Button("前面へ", systemImage: "square.3.layers.3d.top.filled") {
                editor.finishTextEditing()
                editor.document.bringToFront()
            }
            Button("背面へ", systemImage: "square.3.layers.3d.bottom.filled") {
                editor.finishTextEditing()
                editor.document.sendToBack()
            }
            Spacer(minLength: 0)
            Button("削除", systemImage: "trash", role: .destructive) {
                editor.finishTextEditing()
                editor.document.remove()
            }
        }
        .controlSize(.small)
    }
}
