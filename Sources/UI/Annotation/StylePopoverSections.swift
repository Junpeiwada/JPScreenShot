import AppKit
import SwiftUI

// 詳しいスタイル設定の小窓の、注釈の種類別の区画。
// 部品は StylePopoverControls.swift。

// MARK: - 図形

struct FigureStyleSection: View {
    let editor: AnnotationEditor
    let kind: AnnotationKind

    var body: some View {
        let bindings = StyleBindings(editor: editor)
        StyleKindRow(editor: editor, kind: kind)
        StyleColorRow(
            editor: editor, title: "色", color: bindings.binding(\.color, fallback: .red, coalescing: "color"))
        StyleSliderRow(
            editor: editor, title: "太さ",
            value: bindings.binding(\.lineWidth, fallback: 5), range: 1...24)
        if kind == .arrow {
            StyleSegmentedRow(
                title: "先端", selection: bindings.binding(\.arrowHeads, fallback: .end),
                options: [(.none, "なし"), (.end, "片側"), (.both, "両側")])
        }
        StyleSegmentedRow(
            title: "線種", selection: bindings.binding(\.dash, fallback: .solid),
            options: [(.solid, "実線"), (.dashed, "破線")])
        if kind == .rect || kind == .ellipse {
            StyleSegmentedRow(
                title: "塗り", selection: bindings.binding(\.fill, fallback: .none),
                options: [(.none, "なし"), (.translucent, "半透明"), (.solid, "塗る")])
        }
        StyleShadowControls(editor: editor, bindings: bindings)
    }
}

// MARK: - テキスト

struct TextStyleSection: View {
    let editor: AnnotationEditor
    @AppStorage("stylePopover.textDecorationsExpanded") private var decorationsExpanded = false

    var body: some View {
        let bindings = StyleBindings(editor: editor)
        let text = editor.document.selectedAnnotations.first?.style.text ?? TextStyle()

        TextStyleSample(style: text)

        StyleRow(title: "フォント") {
            Picker(
                "フォント",
                selection: bindings.binding(\.text.fontName, fallback: "")
            ) {
                ForEach(FontChoices.choices(including: text.fontName), id: \.postScriptName) { choice in
                    Text(choice.title).tag(choice.postScriptName)
                }
            }
            .labelsHidden()
        }
        StyleRow(title: "ウエイト") {
            Picker("ウエイト", selection: bindings.binding(\.text.weight, fallback: .bold)) {
                ForEach(AnnotationFontWeight.allCases, id: \.self) { weight in
                    Text(weight.title).tag(weight)
                }
            }
            .labelsHidden()
        }
        StyleSliderRow(
            editor: editor, title: "サイズ",
            value: bindings.binding(\.text.size, fallback: 24), range: 8...200)
        StyleColorRow(
            editor: editor, title: "文字色",
            color: bindings.binding(\.text.color, fallback: .white, coalescing: "textColor"))

        // 縁取りと影は普段いじらないので折りたたみ、テキスト用小窓の高さを抑える。
        // 開閉は記憶する。
        DisclosureGroup("縁取りと影", isExpanded: $decorationsExpanded) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                let outlineOn = bindings.binding(\.text.outline.isOn, fallback: true)
                StyleRow(title: "縁取り") {
                    Toggle("縁取り", isOn: outlineOn).labelsHidden().toggleStyle(.switch)
                }
                if outlineOn.wrappedValue {
                    StyleColorRow(
                        editor: editor, title: "縁の色",
                        color: bindings.binding(
                            \.text.outline.color, fallback: .black, coalescing: "outlineColor"))
                    StyleSliderRow(
                        editor: editor, title: "縁の太さ",
                        value: bindings.binding(\.text.outline.width, fallback: 3), range: 1...12)
                }
                StyleShadowControls(editor: editor, bindings: bindings)
            }
            .padding(.top, 8)
        }
    }
}

/// 袋文字の見本。レンダラと同じ描画関数で出すので、仕上がりをその場で確認できる。
struct TextStyleSample: View {
    let style: TextStyle

    var body: some View {
        // 白文字・黒縁が見えるよう、中間の灰色の上に出す。
        Canvas { context, size in
            var sample = style
            sample.size = min(style.size, 30)
            let string = "見本 Abc"
            let measured = AnnotationTextLayout.size(of: string, style: sample)
            context.withCGContext { cg in
                AnnotationTextLayout.draw(
                    string, style: sample,
                    origin: CGPoint(
                        x: (size.width - measured.width) / 2,
                        y: (size.height - measured.height) / 2),
                    in: cg)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 60)
        .background(Color(white: 0.5), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("テキストの見本")
    }
}

// MARK: - ぼかし・モザイク

struct RedactionStyleSection: View {
    let editor: AnnotationEditor
    let kind: AnnotationKind

    var body: some View {
        let bindings = StyleBindings(editor: editor)
        StyleKindRow(editor: editor, kind: kind)
        // 範囲の下限は人の目で読めない強さ（RedactionStyle の定数の根拠を参照）。
        StyleSliderRow(
            editor: editor, title: "強さ",
            value: bindings.binding(\.redaction.strength, fallback: 12),
            range: RedactionStyle.strengthRange(for: kind))
        StyleSegmentedRow(
            title: "形", selection: bindings.binding(\.redaction.shape, fallback: .rectangle),
            options: [(.rectangle, "四角"), (.ellipse, "楕円")])
    }
}

// MARK: - 複数選択

/// 複数選択のときは、全員に共通する項目（色・太さ・影）だけを出す。
/// 効かない種類（ぼかしに色など）は変えない。
struct CommonStyleSection: View {
    let editor: AnnotationEditor

    var body: some View {
        let bindings = StyleBindings(editor: editor)
        let kinds = editor.document.selectedAnnotations.map(\.kind)

        Text("\(kinds.count) 件を選択中")
            .font(.caption)
            .foregroundStyle(.secondary)

        if editor.canChangeColor {
            StyleColorRow(
                editor: editor, title: "色",
                color: Binding(
                    get: { editor.displayedColor ?? .red },
                    set: { editor.setColor($0, coalescing: "color") }),
                currentColors: editor.displayedColors)
        }
        if editor.canChangeLineWidth {
            StyleSliderRow(
                editor: editor, title: "太さ",
                value: Binding(
                    get: { editor.displayedLineWidth ?? 5 },
                    set: { width in editor.setLineWidth(width) }),
                range: 1...24)
        }
        if kinds.contains(where: { $0.layer == .figure }) {
            StyleShadowControls(editor: editor, bindings: bindings, figuresOnly: true)
        }
    }
}
