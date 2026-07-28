import SwiftUI

// 結果ウィンドウの中身（要求 4.3）。
// レイアウトは上に画像、下に OCR テキストの縦積み。
struct ResultView: View {
    @Bindable var model: ResultViewModel

    var body: some View {
        VSplitView {
            imagePane
            textPane
        }
        .frame(minWidth: 480, minHeight: 360)
        .overlay(alignment: .top) {
            if let feedback = model.feedback {
                feedbackBanner(feedback)
            }
        }
        .safeAreaInset(edge: .bottom) {
            buttonBar
        }
    }

    // MARK: - 画像

    private var imagePane: some View {
        GeometryReader { geometry in
            let size = fittedSize(in: geometry.size)
            // 等倍で収まるかどうか。等倍なら .resizable() を通さず
            // そのまま描く（同じ寸法でもリサンプリング経路に入ると
            // わずかに甘くなることがあるため）。
            let isExact = size.width >= CGFloat(model.image.width) - 0.5
            ScrollView([.horizontal, .vertical]) {
                Group {
                    if isExact {
                        Image(decorative: model.image, scale: 1.0)
                    } else {
                        Image(decorative: model.image, scale: 1.0)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: size.width, height: size.height)
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .center
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(.background.secondary)
        .frame(minHeight: 120, idealHeight: 320)
    }

    /// アスペクト比を保って収める。等倍より大きく拡大はしない（4.3）。
    ///
    /// Preview.app はウィンドウに合わせて拡大するため、1x のスクリーン
    /// ショットがぼやけて見える。ここでは等倍を上限にして常に鮮明に出す。
    private func fittedSize(in available: CGSize) -> CGSize {
        let native = model.pixelSize
        guard native.width > 0, native.height > 0 else { return .zero }
        guard available.width > 0, available.height > 0 else { return native }

        let scale = min(
            available.width / native.width,
            available.height / native.height,
            1.0  // 等倍が上限
        )
        return CGSize(width: native.width * scale, height: native.height * scale)
    }

    // MARK: - テキスト

    private var textPane: some View {
        VStack(spacing: 0) {
            modeBar
            Divider()
            textContent
        }
        .frame(minHeight: 80, idealHeight: 180)
        .background(.background)
    }

    /// 認識モードの切替（6.3）。切り替えると即座に再認識される。
    private var modeBar: some View {
        HStack(spacing: 8) {
            Picker("認識モード", selection: $model.mode) {
                ForEach(RecognitionMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if model.isRecognizing {
                ProgressView().controlSize(.small)
            }

            Spacer()

            if !model.isRecognizing, model.lineCount > 0 {
                Text("\(model.lineCount) 行")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var textContent: some View {
        ZStack(alignment: .topLeading) {
            if model.isRecognizing {
                // OCR 処理中はスピナー（4.3）。画像は待たずに先に出ている。
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("テキストを認識中…")
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else if model.hasNoText {
                // OCR が 1 文字も取れなかった場合（4.3）。
                Text("テキストを認識できませんでした")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                // 選択可能かつ編集可能（4.3）。
                TextEditor(text: $model.text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(4)
            }
        }
    }

    // MARK: - ボタン

    private var buttonBar: some View {
        HStack(spacing: 8) {
            Button("画像をコピー") { model.copyImage() }
                .keyboardShortcut("c", modifiers: [.command, .shift])

            Button("テキストをコピー") { model.copyText() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!model.canCopyText)

            Button("保存") { model.save() }
                .keyboardShortcut("s", modifiers: .command)

            Spacer()

            Text("\(Int(model.pixelSize.width)) × \(Int(model.pixelSize.height))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button("閉じる") { model.requestClose?() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func feedbackBanner(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(.separator))
            .padding(.top, 10)
            .transition(.opacity)
    }
}
