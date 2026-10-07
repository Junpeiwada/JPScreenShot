import AppKit
import SwiftUI

// 画像欄の左に置く縦のツールレール（画面構成案 案B）。
//
// 上に 8 ツール、下に色（今の色の丸 1 つ。押すとプリセット 6 色＋「その他の色…」の
// ポップアップ）と太さ（細・中・太）。
// 色・太さは、選択中があればそれに（取り消し 1 回分）、無ければ次に描くものに効く。
// それ以外の設定はポップオーバー（StylePopover）で変える。
struct ToolRail: View {
    @Bindable var editor: AnnotationEditor

    /// 色のポップアップを開いているか。
    @State private var isColorPopoverShown = false
    /// 「その他の色…」で開くカラーパネルの橋渡し。
    @State private var colorPanel = ColorPanelBridge()

    /// レール本体の幅。ウィンドウの初期幅・最小幅の計算にも使う（ResultWindow・ResultView）。
    static let width: CGFloat = 44
    /// 画像欄との境界線（Divider）の太さ。幅の計算ではこれも足す。
    static let dividerWidth: CGFloat = 1
    /// 幅の合計。
    static var totalWidth: CGFloat { width + dividerWidth }

    private static let buttonSize: CGFloat = 30
    private static let spacing: CGFloat = 2
    private static let verticalPadding: CGFloat = 8

    // 色・太さの部品の大きさ。
    /// レールの「今の色」の丸の直径。
    private static let currentColorSize: CGFloat = 22
    /// ポップアップ内のプリセットの丸の直径・間隔。
    private static let swatchSize: CGFloat = 22
    private static let swatchSpacing: CGFloat = 10
    private static let thicknessHeight: CGFloat = 20
    private static let sectionSpacing: CGFloat = 8

    /// 色・太さの区画の高さ（区切り線＋色の丸＋太さ 3 段。要素の間は sectionSpacing）。
    private static var styleSectionHeight: CGFloat {
        let thickness = CGFloat(AnnotationStyleEditing.Thickness.allCases.count) * thicknessHeight
            + CGFloat(AnnotationStyleEditing.Thickness.allCases.count - 1) * 2
        return 1 + currentColorSize + thickness + sectionSpacing * 2
    }

    /// ツールと色・太さを全部並べるのに必要な高さ。画像欄の最小高さには使わない
    /// （狭いときはレールが縦スクロールする）。ウィンドウの初期高さで、初期表示から
    /// レールが全部見えるようにするために使う（ResultWindow）。
    static var fullHeight: CGFloat {
        let count = CGFloat(AnnotationTool.allCases.count)
        return count * buttonSize + (count - 1) * spacing + verticalPadding * 2
            + sectionSpacing + styleSectionHeight
    }

    var body: some View {
        // 画像欄が低いときはレール全体を縦にスクロールさせる（レールの高さで
        // 画像欄の最小高さが決まり、OCR 欄を広げられなくなるのを避ける）。
        // 十分高いときは色・太さを下端に寄せる。
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(spacing: Self.spacing) {
                    ForEach(AnnotationTool.allCases) { tool in
                        toolButton(tool)
                    }
                    Spacer(minLength: 0)
                    styleSection
                }
                .padding(.vertical, Self.verticalPadding)
                .frame(width: Self.width)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: Self.width)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("注釈ツール")
    }

    private func toolButton(_ tool: AnnotationTool) -> some View {
        let isSelected = editor.tool == tool
        return Button {
            // 入力途中のテキストは、ツールを切り替える前に確定する。
            editor.selectTool(tool)
        } label: {
            // 固定の pt 数ではなく Dynamic な imageScale で大きさを決める。
            Image(systemName: tool.symbolName)
                .imageScale(.large)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .background(
                    isSelected ? Color.accentColor.opacity(0.2) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(tool.helpText)
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: 色・太さ

    private var styleSection: some View {
        VStack(spacing: Self.sectionSpacing) {
            Divider().padding(.horizontal, 6)
            // 無効のときの薄めは `.disabled` に任せる（opacity との二重がけをしない）。
            // 効かない理由はツールチップで示す。
            colorSection
                .disabled(!editor.canChangeColor)
                .help(editor.canChangeColor ? "" : Self.disabledReason(for: "色", editor: editor))
            thicknessSection
                .disabled(!editor.canChangeLineWidth)
                .help(
                    editor.canChangeLineWidth
                        ? "" : Self.disabledReason(for: "太さ", editor: editor))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("色と太さ")
    }

    /// 色・太さが効かない理由。
    private static func disabledReason(for item: String, editor: AnnotationEditor) -> String {
        editor.document.selectedAnnotations.isEmpty
            ? "このツールでは\(item)を変えられません"
            : "選択中の注釈には\(item)の設定がありません（ぼかし・モザイクなど）"
    }

    /// 今の色を表す丸ボタン 1 つ。押すとポップアップでプリセットと「その他の色…」を選ぶ。
    private var colorSection: some View {
        let current = editor.displayedColor
        return Button {
            isColorPopoverShown.toggle()
        } label: {
            ColorSwatchCircle(color: current ?? .red, diameter: Self.currentColorSize)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("色を選ぶ（現在: \(current.flatMap(AnnotationStyleEditing.presetName(of:)) ?? "指定色")）")
        .accessibilityLabel("色")
        .accessibilityValue(current.flatMap(AnnotationStyleEditing.presetName(of:)) ?? "指定色")
        .popover(isPresented: $isColorPopoverShown, arrowEdge: .trailing) {
            colorPopoverContent(current: current)
        }
    }

    /// プリセット 6 色（3 列 × 2 行）と「その他の色…」。プリセットを選んだら閉じる。
    private func colorPopoverContent(current: RGBAColor?) -> some View {
        let columns = Array(
            repeating: GridItem(.fixed(Self.swatchSize), spacing: Self.swatchSpacing), count: 3)
        return VStack(spacing: 12) {
            LazyVGrid(columns: columns, spacing: Self.swatchSpacing) {
                ForEach(Array(AnnotationStyleEditing.presetColors.enumerated()), id: \.offset) { _, preset in
                    swatch(preset, isCurrent: current?.isClose(to: preset) ?? false)
                }
            }
            Button("その他の色…") {
                isColorPopoverShown = false
                colorPanel.open(editor: editor)
            }
            .controlSize(.small)
        }
        .padding(14)
    }

    private func swatch(_ color: RGBAColor, isCurrent: Bool) -> some View {
        Button {
            editor.setColor(color)
            isColorPopoverShown = false
        } label: {
            ColorSwatchCircle(color: color, diameter: Self.swatchSize, isCurrent: isCurrent)
                .contentShape(Circle().inset(by: -3))
        }
        .buttonStyle(.plain)
        .help(AnnotationStyleEditing.presetName(of: color) ?? "色")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityLabel(AnnotationStyleEditing.presetName(of: color) ?? "色")
    }

    private var thicknessSection: some View {
        let current = editor.displayedLineWidth
        return VStack(spacing: 2) {
            ForEach(AnnotationStyleEditing.Thickness.allCases, id: \.self) { thickness in
                let isCurrent = current.map { abs($0 - thickness.points) < 0.01 } ?? false
                Button {
                    editor.setLineWidth(thickness.points)
                } label: {
                    // 太さそのものを線で見せる。
                    RoundedRectangle(cornerRadius: thickness.points / 2)
                        .fill(isCurrent ? Color.accentColor : Color.primary)
                        .frame(width: 22, height: thickness.points)
                        .frame(width: 30, height: Self.thicknessHeight)
                        .background(
                            isCurrent ? Color.accentColor.opacity(0.2) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("太さ: \(thickness.title)（\(Int(thickness.points))pt）")
                .accessibilityLabel("太さ \(thickness.title)")
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
    }
}

// MARK: - カラーパネルの橋渡し

/// 「その他の色…」で NSColorPanel を開き、選んだ色をエディタへ流す。
///
/// SwiftUI の ColorPicker はポップアップ（閉じると消える）の中に置けないため、
/// パネルを直接開く。ドラッグ中の連続した変更は取り消し 1 回にまとめる。
@MainActor
final class ColorPanelBridge: NSObject {
    private weak var editor: AnnotationEditor?

    /// いまカラーパネルの宛先になっているブリッジ（自分が宛先のときだけ解除するために覚える）。
    private static weak var active: ColorPanelBridge?

    /// `editor` を宛先にしているなら、パネルの宛先を外す。ウィンドウを閉じる・隠すときに呼ぶ
    /// （別のウィンドウが設定した宛先は触らない）。
    static func detach(for editor: AnnotationEditor) {
        guard let bridge = active, bridge.editor === editor else { return }
        guard NSColorPanel.sharedColorPanelExists else { return }
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
        active = nil
    }

    func open(editor: AnnotationEditor) {
        self.editor = editor
        // 開いている小窓（StylePopover）にも ColorPicker がある。色が 2 か所に入らないよう、
        // 先に小窓を閉じる。
        editor.transientUIDismisser?()
        Self.active = self
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(nil)
        panel.setAction(nil)
        if let color = editor.displayedColor { panel.color = color.nsColor }
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard let editor else { return }
        let new = RGBAColor(Color(nsColor: sender.color))
        // ユーザーが操作した変更だけ適用する（選択が変わった直後に前の色が届いても
        // 新しい選択へ入れない）。
        if editor.acceptsPickerColor(new, currentColors: editor.displayedColors) {
            editor.setColor(new, coalescing: "railColor")
        }
    }
}
