import AppKit
import SwiftUI

// 詳しいスタイル設定の小窓（StylePopover）で使う共通の部品。
// 種類別の区画（StylePopoverSections.swift）が組み合わせて使う。

// MARK: - 値の読み書き

/// 選択中の注釈のスタイルへのバインディングを作る。
///
/// 読むのは先頭の選択中の注釈。書くのは `editor.updateStyle` 経由で、選択中すべてに効き、
/// 履歴は 1 回分（`coalescing` を渡した連続操作は 1 回にまとまる）。
@MainActor
struct StyleBindings {
    let editor: AnnotationEditor

    private var first: Annotation? { editor.document.selectedAnnotations.first }

    func binding<T>(
        _ keyPath: WritableKeyPath<AnnotationStyle, T>,
        fallback: T,
        coalescing key: String? = nil,
        figuresOnly: Bool = false
    ) -> Binding<T> {
        Binding(
            get: { first?.style[keyPath: keyPath] ?? fallback },
            set: { value in
                editor.updateStyle(coalescing: key) { style, kind in
                    if figuresOnly, kind.layer != .figure { return }
                    style[keyPath: keyPath] = value
                }
            })
    }
}

// MARK: - 部品

/// 項目名の列幅。Grid 内でも、折りたたみの中の別の Grid でも項目名の右端とコントロールの
/// 左端が揃うよう固定する。
private let labelColumnWidth: CGFloat = 64

/// 色の丸。白・黒が背景に溶けないよう細い縁を付け、現在の色は外側にアクセント色のリングを出す。
/// 色の選択肢（レールのポップアップ・小窓）で共通。押せる範囲（frame・contentShape）は呼び出し側で決める。
struct ColorSwatchCircle: View {
    let color: RGBAColor
    let diameter: CGFloat
    /// リングを出すか（現在の色か）。`false` のときは見えない。
    var isCurrent = false

    var body: some View {
        Circle()
            .fill(Color(color))
            .frame(width: diameter, height: diameter)
            .overlay(Circle().stroke(.primary.opacity(0.3), lineWidth: 1))
            .overlay(
                Circle().stroke(Color.accentColor, lineWidth: 2)
                    .padding(-3)
                    .opacity(isCurrent ? 1 : 0))
    }
}

/// ラベル付きの行。項目名は右揃え、コントロールは左端を揃える。
struct StyleRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: labelColumnWidth, alignment: .trailing)
                .gridColumnAlignment(.trailing)
            HStack(spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 色の行。プリセットとカラーパネル。
struct StyleColorRow: View {
    let editor: AnnotationEditor
    let title: String
    @Binding var color: RGBAColor
    /// 「同じ色なら何もしない」の比較対象。複数選択では全員の色（省略時は `color` だけ）。
    var currentColors: [RGBAColor]?

    var body: some View {
        StyleRow(title: title) {
            // 押せる範囲は 22pt 角。見た目の丸は 16pt のまま。
            HStack(spacing: 0) {
                ForEach(Array(AnnotationStyleEditing.presetColors.enumerated()), id: \.offset) { _, preset in
                    let name = AnnotationStyleEditing.presetName(of: preset) ?? "色"
                    Button {
                        color = preset
                    } label: {
                        ColorSwatchCircle(
                            color: preset, diameter: 16, isCurrent: color.isClose(to: preset))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(name)
                    .accessibilityLabel(name)
                    .accessibilityAddTraits(color.isClose(to: preset) ? .isSelected : [])
                }
            }
            ColorPicker(
                "\(title)（その他の色）",
                selection: Binding(
                    get: { Color(color) },
                    set: { picked in
                        // ユーザーが操作した変更だけ適用する（選択が変わった直後に
                        // 前の色が届いても、新しい選択へ入れない）。
                        let new = RGBAColor(picked)
                        if editor.acceptsPickerColor(new, currentColors: currentColors ?? [color]) { color = new }
                    }),
                supportsOpacity: false
            )
            .labelsHidden()
        }
    }
}

/// スライダーの行。ドラッグの開始・終了で履歴を 1 回にまとめる。
/// 正確な値を入れられるよう、数値欄とステッパーを併せて置く。
struct StyleSliderRow: View {
    let editor: AnnotationEditor
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var isEnabled = true

    /// 数値欄・ステッパーからの変更。範囲に収め、1 回の操作を取り消し 1 回分にする。
    private var typed: Binding<Double> {
        Binding(
            get: { value },
            set: { new in
                let clamped = min(max(new.rounded(), range.lowerBound), range.upperBound)
                guard clamped != value else { return }
                editor.beginContinuousStyleChange()
                value = clamped
                editor.endContinuousStyleChange()
            })
    }

    var body: some View {
        StyleRow(title: title) {
            Slider(value: $value, in: range) { editing in
                // ドラッグ中は履歴を積まず、離したときに 1 回分として確定する。
                if editing {
                    editor.beginContinuousStyleChange()
                } else {
                    editor.endContinuousStyleChange()
                }
            }
            .accessibilityLabel(title)
            TextField(title, value: typed, format: .number.precision(.fractionLength(0)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 44)
                .textFieldStyle(.roundedBorder)
                // Return で確定したら、キー操作（⌫・矢印・ツールキー）がすぐ効くよう
                // フォーカスをキャンバスへ戻す。
                .onSubmit { editor.canvasFocuser?() }
            Stepper(title, value: typed, in: range, step: 1)
                .labelsHidden()
        }
        .disabled(!isEnabled)
    }
}

/// 列挙を横並びで選ぶ行。
struct StyleSegmentedRow<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        StyleRow(title: title) {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

/// 影の項目（オン/オフ・ぼかし・距離）。
struct StyleShadowControls: View {
    let editor: AnnotationEditor
    let bindings: StyleBindings
    var figuresOnly = false

    var body: some View {
        let isOn = bindings.binding(\.shadow.isOn, fallback: false, figuresOnly: figuresOnly)
        StyleRow(title: "影") {
            Toggle("影", isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
        if isOn.wrappedValue {
            StyleSliderRow(
                editor: editor, title: "ぼかし",
                value: bindings.binding(\.shadow.blur, fallback: 4, figuresOnly: figuresOnly),
                range: 0...20)
            StyleSliderRow(
                editor: editor, title: "距離",
                value: bindings.binding(\.shadow.distance, fallback: 2, figuresOnly: figuresOnly),
                range: 0...20)
        }
    }
}

/// 種類の切り替え（矢印⇔線⇔四角⇔円、ぼかし⇔モザイク）。`document.changeKind` を使う。
struct StyleKindRow: View {
    let editor: AnnotationEditor
    let kind: AnnotationKind

    var body: some View {
        StyleRow(title: "種類") {
            Picker(
                "種類",
                selection: Binding(get: { kind }, set: { editor.changeKind(to: $0) })
            ) {
                ForEach(kind.switchableKinds, id: \.self) { option in
                    let tool = AnnotationTool.allCases.first { $0.kind == option }
                    Label(tool?.title ?? "", systemImage: tool?.symbolName ?? "questionmark")
                        .labelStyle(.iconOnly)
                        .help(tool?.title ?? "")
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}
