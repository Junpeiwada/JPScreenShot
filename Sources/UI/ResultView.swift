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
            ScrollView([.horizontal, .vertical]) {
                imageContent(in: geometry.size)
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

    @ViewBuilder
    private func imageContent(in available: CGSize) -> some View {
        let image = Image(decorative: model.image, scale: 1.0)

        if model.actualSize {
            // 等倍（1:1）。リサンプリングを一切通さないので、画面から
            // 取得したピクセルがそのまま表示される。
            // 収まらない場合はスクロールで見る。
            image
        } else {
            let size = fittedSize(in: available)
            image
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
        }
    }

    /// アスペクト比を保って収める。等倍より大きく拡大はしない（4.3）。
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
    ///
    /// 認識中の表示で要素を出し入れすると Picker の位置や右端のラベル幅が
    /// 動いてしまうので、行数ラベルは常設して不透明度だけを変える。
    /// 進捗表示はテキストペイン側のオーバーレイが担う。
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

            Spacer()

            Text("\(model.lineCount) 行")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .opacity(model.isRecognizing || model.lineCount == 0 ? 0 : 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var textContent: some View {
        // TextEditor は常に置いたままにする。モード切替（6.3）で
        // ビュー階層を差し替えるとペインの寸法・スクロール位置・カーソルが
        // 一瞬動いてしまうため、状態はオーバーレイと不透明度だけで表す。
        ZStack(alignment: .topLeading) {
            // 選択可能かつ編集可能（4.3）。
            TextEditor(text: $model.text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
                // 認識中は前の結果を薄く残す。編集は受け付けない。
                .opacity(model.isRecognizing ? 0.35 : 1)
                .disabled(model.isRecognizing)

            // OCR が 1 文字も取れなかった場合（4.3）。
            if model.hasNoText, !model.isRecognizing {
                Text("テキストを認識できませんでした")
                    .foregroundStyle(.secondary)
                    .padding()
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .top) {
            // OCR 処理中の表示（4.3）。重ねるだけなので下の寸法に影響しない。
            if model.isRecognizing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("テキストを認識中…")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(.separator))
                .padding(.top, 8)
                .allowsHitTesting(false)
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

            // 等倍（1:1）とウィンドウに合わせる表示の切り替え。
            // 1x ディスプレイでは縮小するとリサンプリングでぼやけるため
            // 既定は等倍。
            Toggle("等倍", isOn: $model.actualSize)
                .toggleStyle(.checkbox)
                .help("画面のピクセルをそのまま表示します。オフにするとウィンドウに合わせて縮小します。")

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
