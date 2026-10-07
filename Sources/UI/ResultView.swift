import SwiftUI

// 結果ウィンドウの中身（要求 4.3）。
// レイアウトは上に画像、下に OCR テキストの縦積み。
struct ResultView: View {
    @Bindable var model: ResultViewModel

    /// ウィンドウの外周に引く線の色。アプリアイコンの水色に揃える。
    /// 撮った画像がウィンドウの形をしていても、結果ウィンドウと見分けられる
    /// ようにするための目印。
    private static let borderColor = Color(red: 0x22 / 255, green: 0xAE / 255, blue: 0xDB / 255)
    private static let borderWidth: CGFloat = 3
    /// macOS 26 の標準ウィンドウの角の半径（NSWindow の _cornerRadius を実測）。
    /// ずれても角の線が少し太る・細るだけで、隙間は出ない。
    private static let windowCornerRadius: CGFloat = 16

    /// 画像の外側に引く線の太さ。角丸にせずカチッとした四角で囲み、
    /// ドロップシャドウと合わせて「置かれた画像」だと分かるようにする。
    private static let imageBorderWidth: CGFloat = 2
    /// 画像のまわりの余白。線と影が見える分を空ける。
    /// ResultWindow の初期サイズ計算でもこの分を足す。
    static let imageMargin: CGFloat = 16

    /// 下段のバー（OCR バー・モードバー・ボタンバー）と、重ねて出すバナーの余白。
    /// 左端が揃うよう全部同じ値にする。
    private static let barHorizontalPadding: CGFloat = 12
    private static let barVerticalPadding: CGFloat = 8

    /// テキスト欄の初期の高さ。OCR を始めたときにウィンドウを伸ばす量（ResultWindow）も同じ値にする。
    static let defaultTextPaneHeight: CGFloat = 180
    /// テキスト欄の高さ。
    @State private var textPaneHeight: CGFloat = ResultView.defaultTextPaneHeight
    @State private var dragStartHeight: CGFloat?
    /// ウィンドウ全体の高さ（テキスト欄の上限の計算用）。
    @State private var containerHeight: CGFloat = 0
    /// ボタンバーの狭い版を、ボタンが最も多い状態で並べたときの幅（実測。余白は含まない）。
    /// ウィンドウの最小幅をこれに合わせ、どの状態でもボタンが切れないようにする。
    @State private var compactBarWidth: CGFloat = 0

    private static let minTextPaneHeight: CGFloat = 80
    /// 画像欄の最小高さ。
    private static let minImagePaneHeight: CGFloat = 120
    /// ボタンバー + 仕切りなどの固定の高さの目安。
    private static let fixedChromeHeight: CGFloat = 60

    /// テキスト欄の上限。画像欄の最小高さを残す（containerHeight 未計測の間は制限しない）。
    private var maxTextPaneHeight: CGFloat {
        guard containerHeight > 0 else { return .greatestFiniteMagnitude }
        return max(
            Self.minTextPaneHeight,
            containerHeight - Self.minImagePaneHeight - Self.fixedChromeHeight)
    }

    var body: some View {
        // ボタンバーは safeAreaInset ではなく VStack の兄弟として置く。
        //
        // safeAreaInset は下段（テキスト欄）の中の TextEditor にまで inset が
        // 伝わらず、テキストの末尾がボタンバーの下に隠れて最後までスクロール
        // できなくなっていた（VSplitView 時代の不具合）。実体のある領域として
        // 積む方が確実なので、今の自前の仕切りでもこの構成を保つ。
        VStack(spacing: 0) {
            // 画像欄（レール + キャンバス）は OCR の前後で**同じ位置・同じ構造**に置く。
            // 下段だけを if で切り替える。画像欄を別の分岐（テキスト欄ありと無し）に
            // 置くと、SwiftUI から見て別のビューになり、キャンバス（NSView）が作り直されて
            // 入力途中のテキスト・ポップオーバー・フォーカスの状態が失われる。
            imagePane
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.hasStartedRecognition {
                // テキスト欄。VSplitView は使わず、自前の仕切りで高さを変える
                // （VSplitView だと画像欄が分岐ごと作り直される）。
                splitHandle
                // 高さは「希望」。ウィンドウを縮めたときは、画像欄の最小高さを保つため
                // コンテナ高さから計算した上限へ収める（固定高さだと縮められなくなる）。
                textPane
                    .frame(height: min(textPaneHeight, maxTextPaneHeight))
            } else {
                // OCR を始めるまではテキスト欄を 1 行のバーまで縮め、
                // 画像に場所を譲る（OCR-01）。
                Divider()
                collapsedTextBar
            }

            Divider()
            buttonBar
        }
        // 幅は「ボタンバーの狭い版が収まる幅」と「480 + ツールレール」の大きいほう。
        // 以前は 480 + レールの固定値で、SDR/HDR・保存形式のセグメントを足したら
        // ボタンバーが収まらなくなった（ViewThatFits は収まらない最後の候補をそのまま出し、
        // 右端の「等倍」「閉じる」が切れる）。目算の定数ではなく実測で決める。
        // 高さの最小は従来どおり。レールは画像欄が低いときは縦スクロールする。
        .frame(minWidth: minimumWidth, minHeight: 360)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { containerHeight = $0 }
        .overlay(alignment: .top) {
            if let feedback = model.feedback {
                feedbackBanner(feedback)
            }
        }
        // タイトルバーは透明にしてあるので（ResultWindow）、その領域を
        // 標準のウィンドウ背景で塗って見た目を元のタイトルバーに揃える。
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay { windowBorder }
    }

    /// ウィンドウの外周の線。タイトルバーまで回すため安全領域を無視する。
    private var windowBorder: some View {
        RoundedRectangle(cornerRadius: Self.windowCornerRadius, style: .continuous)
            .strokeBorder(Self.borderColor, lineWidth: Self.borderWidth)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    /// 画像欄とテキスト欄の仕切り。細い線に、つかみやすい透明な帯を重ねる。
    /// 上へ引くとテキスト欄が高くなる。
    private var splitHandle: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.rowResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStartHeight ?? textPaneHeight
                                dragStartHeight = start
                                textPaneHeight = min(
                                    max(start - value.translation.height, Self.minTextPaneHeight),
                                    maxTextPaneHeight)
                            }
                            .onEnded { _ in dragStartHeight = nil })
            }
            // VoiceOver でも高さを変えられるようにする（ドラッグの代わり）。
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("テキスト欄の高さ")
            .accessibilityValue("\(Int(min(textPaneHeight, maxTextPaneHeight))) ポイント")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = 24
                let current = min(textPaneHeight, maxTextPaneHeight)
                switch direction {
                case .increment:
                    textPaneHeight = min(current + step, maxTextPaneHeight)
                case .decrement:
                    textPaneHeight = max(current - step, Self.minTextPaneHeight)
                @unknown default:
                    break
                }
            }
    }

    // MARK: - 画像

    /// 左のツールレール + 右の画像（キャンバス）。
    /// OCR バーとボタンバーは全幅のままなので、レールはこの欄の中だけに置く。
    private var imagePane: some View {
        HStack(spacing: 0) {
            ToolRail(editor: model.editor)
            Divider()
            canvasPane
        }
        .frame(minHeight: Self.minImagePaneHeight, idealHeight: 320)
    }

    private var canvasPane: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                imageContent(in: geometry.size)
                    .overlay {
                        // 線は画像の外側に描く。内側に描くと端の画素が隠れる。
                        // マウスはキャンバスへ通す（描画・選択を邪魔しない）。
                        Rectangle()
                            .stroke(.black, lineWidth: Self.imageBorderWidth)
                            .padding(-Self.imageBorderWidth / 2)
                            .allowsHitTesting(false)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    .padding(Self.imageMargin)
                    // 小さい画像は欄の中央に置く。ScrollView の中では maxWidth: .infinity が
                    // 効かない（大きさを提案されない）ため、欄の大きさを最小値として与える。
                    .frame(
                        minWidth: geometry.size.width,
                        minHeight: geometry.size.height,
                        alignment: .center
                    )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(.background.secondary)
        // 実寸を測って伝える（初期サイズの見積もりの不足を、開いた直後に 1 回だけ補正する）。
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            model.onCanvasViewportChange?(size)
        }
    }

    private func imageContent(in available: CGSize) -> some View {
        // 画像はキャンバス（AppKit の NSView）が描く。キャンバスは自分の幅と
        // pointSize から表示倍率を求めるので、ここでは表示サイズだけを決める。
        //
        // 画像の倍率はキャプチャ時のもの（pointSize = ピクセル ÷ scale）で扱う。
        // ここを 1.0 に固定して「画像の 1 ピクセル = 1 ポイント」と解釈すると、
        // Retina（2x）で撮った画像が画面の 2 倍の大きさで表示されてしまう。
        // 実際の倍率を伝えることで、撮った範囲が画面上で占めていたのと同じ大きさになる。
        let size: CGSize
        if model.actualSize {
            // 等倍 = 撮影時に画面で見えていたのと同じ大きさ。
            // 収まらない場合はスクロールで見る。
            //
            // 画素が間引かれないのは「撮影元と表示先の倍率が同じとき」だけ
            // （2x で撮って 2x に出す場合、1 ポイントに 2 ピクセルが描かれる）。
            // 混在 DPI 環境で 2x のディスプレイで撮った結果ウィンドウを 1x の
            // ディスプレイへ動かすと、2 ピクセルが 1 ピクセルに落ちるため
            // ダウンサンプリングが起きる。
            //
            // これは「画面と同じ大きさで出す」を選んだ以上避けられない。
            // ピクセル 1:1 を優先すると、今度は 2x で撮った画像が 1x 画面で
            // 2 倍の大きさに引き伸ばされて表示されてしまう（この修正で直した
            // 元の不具合そのもの）。表示サイズの正しさを優先する。
            size = model.pointSize
        } else {
            // 縮小表示。キャンバス側が .high 補間で描く。
            size = fittedSize(in: available)
        }
        // ScrollView の中ではビューのサイズを固定する。
        return AnnotationCanvas(
            editor: model.editor, image: model.image, pointSize: model.pointSize,
            hdrImage: model.editor.hdrImage
        )
        .frame(width: size.width, height: size.height)
    }

    /// アスペクト比を保って収める。等倍より大きく拡大はしない（4.3）。
    ///
    /// 基準はポイント寸法。ピクセル寸法で比べると Retina では常に
    /// 「画面より大きい」と判定され、収まる画像まで縮小されてしまう。
    private func fittedSize(in available: CGSize) -> CGSize {
        let native = model.pointSize
        guard native.width > 0, native.height > 0 else { return .zero }
        // 線と影のための余白を除いた広さに収める。
        let available = CGSize(
            width: available.width - Self.imageMargin * 2,
            height: available.height - Self.imageMargin * 2
        )
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
        .background(.background)
    }

    /// OCR を始める前のテキスト欄（OCR-01）。
    ///
    /// 認識モードはここで先に選んでおける。モードごとに認識をやり直すと
    /// 時間がかかるため、押す前に決められる方が無駄がない。
    private var collapsedTextBar: some View {
        HStack(spacing: 8) {
            Button("テキストを認識", systemImage: "text.viewfinder") {
                model.startRecognition()
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("テキストを認識（⌘R）")

            modePicker

            Spacer()
        }
        .padding(.horizontal, Self.barHorizontalPadding)
        .padding(.vertical, Self.barVerticalPadding)
        .background(.background)
    }

    private var modePicker: some View {
        Picker("認識モード", selection: $model.mode) {
            ForEach(RecognitionMode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// 認識モードの切替（6.3）。切り替えると即座に再認識される。
    ///
    /// 認識中の表示で要素を出し入れすると Picker の位置や右端のラベル幅が
    /// 動いてしまうので、行数ラベルは常設して不透明度だけを変える。
    /// 進捗表示はテキストペイン側のオーバーレイが担う。
    private var modeBar: some View {
        HStack(spacing: 8) {
            modePicker

            Spacer()

            Text("\(model.lineCount) 行")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .opacity(model.isRecognizing || model.lineCount == 0 ? 0 : 1)
        }
        .padding(.horizontal, Self.barHorizontalPadding)
        .padding(.vertical, Self.barVerticalPadding)
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
                .padding(.horizontal, Self.barHorizontalPadding)
                .padding(.vertical, Self.barVerticalPadding)
                .glassEffect(in: Capsule())
                .padding(.top, 8)
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - ボタン

    /// ウィンドウの最小幅。ボタンバーの狭い版（実測）に左右の余白を足した幅を下回らない。
    private var minimumWidth: CGFloat {
        max(480 + ToolRail.totalWidth, ceil(compactBarWidth) + Self.barHorizontalPadding * 2)
    }

    /// 最小幅を決めるための、見えない狭い版のボタンバー。
    ///
    /// 「テキストをコピー」は OCR を始めるまで出ないが、ここでは常に出した状態で測る。
    /// 表示中の状態で測ると OCR 開始のたびに最小幅が伸び、ウィンドウの幅が勝手に変わるため。
    /// `.fixedSize()` で理想の幅のまま測る（親の幅に合わせて縮んだ値を拾わない）。
    private var barWidthProbe: some View {
        buttonBarContent(compact: true, showsTextCopy: true)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { compactBarWidth = $0 }
            .hidden()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// ボタンバー。幅が足りないときはラベルを省略せず、アイコンだけの狭い版に切り替える
    /// （`ViewThatFits`）。ボタンは `.fixedSize()` で、文字が途中で切れないようにする。
    private var buttonBar: some View {
        ViewThatFits(in: .horizontal) {
            buttonBarContent(compact: false)
            buttonBarContent(compact: true)
        }
        .padding(.horizontal, Self.barHorizontalPadding)
        .padding(.vertical, Self.barVerticalPadding)
        .background(.bar)
        .background { shortcutButtons }
        .background(alignment: .leading) { barWidthProbe }
    }

    /// 文字つき（広い版）かアイコンのみ（狭い版）のボタン。
    private func barButton(
        _ title: String, systemImage: String, compact: Bool, showsIconWhenWide: Bool = false,
        help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if compact {
                Label(title, systemImage: systemImage).labelStyle(.iconOnly)
            } else if showsIconWhenWide {
                Label(title, systemImage: systemImage).labelStyle(.titleAndIcon)
            } else {
                Text(title)
            }
        }
        .help(help)
        .fixedSize()
    }

    /// SDR/HDR の切替。HDR 版が無いときは無効にして理由を出す。
    private var dynamicRangePicker: some View {
        Picker("表示", selection: $model.dynamicRange) {
            Text("SDR").tag(ImageDynamicRange.sdr)
            Text("HDR").tag(ImageDynamicRange.hdr)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(!model.hasHDR)
        .help(model.hasHDR
            ? "SDR と HDR の表示を切り替えます。コピー・保存も選んだほうになります。"
            : "この画面・撮影内容には HDR の明るさがありません")
        .accessibilityLabel("ダイナミックレンジ")
    }

    /// 保存形式（HEIC / PNG / JPG）。保存は「この形式 × 表示中のダイナミックレンジ」。
    /// コピーには効かない（HDR はゲインマップ JPEG、SDR は PNG＋TIFF 固定）。
    private var exportFormatPicker: some View {
        Picker("保存形式", selection: $model.exportFormat) {
            ForEach(ImageExporter.Format.allCases, id: \.self) { format in
                Text(format.label).tag(format)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("保存する形式。HDR 表示中は、HEIC・JPG はゲインマップ付き、PNG は 16bit PQ で保存します。")
        .accessibilityLabel("保存形式")
    }

    /// - Parameter showsTextCopy: 「テキストをコピー」を出すか。既定は OCR を始めたら出す。
    ///   最小幅の計測（`barWidthProbe`）だけが常に true で呼ぶ。
    private func buttonBarContent(compact: Bool, showsTextCopy: Bool? = nil) -> some View {
        HStack(spacing: 8) {
            // CAP-09: 結果を見ながら続けて撮る。選択中は結果ウィンドウを隠す。
            // 赤の塗りつぶし・白文字で目立たせる（ユーザー要望）。HIG では赤は破壊的操作の
            // 色だが、新規キャプチャは前の注釈を確認なしに破棄する操作でもあるので
            // 注意を引く色として許容する。
            barButton(
                "新規キャプチャ", systemImage: "plus.viewfinder", compact: compact,
                showsIconWhenWide: true, help: "新規キャプチャ（⌘N）"
            ) {
                model.requestNewCapture?()
            }
            .buttonStyle(FilledRedButtonStyle())

            Divider().frame(height: 16)

            dynamicRangePicker
            exportFormatPicker

            barButton(
                "画像をコピー", systemImage: "photo.on.rectangle", compact: compact,
                help: "画像をコピー（⇧⌘C）"
            ) { model.copyImage() }
            .disabled(model.isExporting)

            // Cmd+C は割り当てない。TextEditor で一部を選択して
            // コピーする操作を奪ってしまう（4.3 で誤認識をその場で直して
            // 部分的にコピーする使い方を想定している）。
            // OCR を始めるまではコピーするテキストが無いので出さない。
            if showsTextCopy ?? model.hasStartedRecognition {
                barButton(
                    "テキストをコピー", systemImage: "doc.on.clipboard", compact: compact,
                    help: "テキストをコピー（⌥⌘C）"
                ) { model.copyText() }
                .disabled(!model.canCopyText)
            }

            barButton(
                "保存", systemImage: "square.and.arrow.down", compact: compact,
                help: "保存（⌘S）"
            ) { model.save() }
            .disabled(model.isExporting)

            Spacer(minLength: 0)

            // 注釈の取り消し・やり直し。ショートカットは付けない。⌘Z は
            // メインメニュー経由で First Responder に届く（キャンバスと
            // OCR テキスト欄で取り消しの対象が自然に分かれる）。
            // SwiftUI の .keyboardShortcut("z") だと OCR テキスト欄の ⌘Z を奪う。
            Button {
                model.editor.finishTextEditing()
                model.editor.document.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!model.editor.document.canUndo)
            .help("注釈を取り消す（⌘Z）")
            .accessibilityLabel("取り消し")
            .fixedSize()

            Button {
                model.editor.finishTextEditing()
                model.editor.document.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!model.editor.document.canRedo)
            .help("注釈をやり直す（⇧⌘Z）")
            .accessibilityLabel("やり直し")
            .fixedSize()

            // 等倍（画面と同じ大きさ）とウィンドウに合わせる表示の切り替え。
            // 縮小するとリサンプリングでぼやけるため既定は等倍。
            Toggle("等倍", isOn: $model.actualSize)
                .toggleStyle(.checkbox)
                .help("撮影時に画面で見えていたのと同じ大きさで表示します。オフにするとウィンドウに合わせて縮小します。")
                .fixedSize()

            // 寸法は保存・コピーされる実データに合わせてピクセルで出す。
            // 狭い版では隠す（ラベルを省略するより、配置を変えて収める）。
            if !compact {
                Text("\(Int(model.pixelSize.width)) × \(Int(model.pixelSize.height))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            // Esc は段階的に使う: テキスト入力中は確定、キャンバスにフォーカスがあって
            // 選択があれば選択解除、それ以外は閉じる。前 2 つのときは「閉じる」の
            // ショートカットを外す（付けたままだと SwiftUI が先に受けてウィンドウが閉じ、
            // 入力や選択解除より先に閉じてしまう）。OCR テキスト欄にフォーカスがあるときは
            // 従来どおり Esc で閉じる。
            // （Esc の割り当ては `shortcutButtons` 側。ここは表示用でショートカットは持たない。）
            Button("閉じる") { model.requestClose?() }
                .help("閉じる（Esc）")
                .fixedSize()
        }
    }

    /// キーボードショートカットを持つボタン（1 組だけ）。
    ///
    /// `ViewThatFits` の広い版・狭い版の両方に `.keyboardShortcut` を付けると二重登録になり、
    /// ⌘S などが 2 回走るおそれがある。そのため表示用のボタン（`buttonBarContent`）には
    /// ショートカットを付けず、ここに 1 組だけ置く。
    ///
    /// 見えなくするのは `.hidden()` ではなく「大きさ 0 ＋ opacity 0」にする。`.hidden()` は
    /// ビューを階層から外す扱いになり、ショートカットが効かない場合があるため。
    /// 階層には残り有効なので、ショートカットは普通に効く。マウス・VoiceOver には出さない。
    private var shortcutButtons: some View {
        ZStack {
            Button("新規キャプチャ") { model.requestNewCapture?() }
                .keyboardShortcut("n", modifiers: .command)
            Button("画像をコピー") { model.copyImage() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            if model.hasStartedRecognition {
                Button("テキストをコピー") { model.copyText() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(!model.canCopyText)
            }
            Button("保存") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
            // Esc は段階的に使う: テキスト入力中は確定、キャンバスにフォーカスがあって
            // 選択があれば選択解除、それ以外は閉じる。前 2 つのときは「閉じる」の
            // ショートカットを外す（付けたままだと SwiftUI が先に受けてウィンドウが閉じ、
            // 入力や選択解除より先に閉じてしまう）。OCR テキスト欄にフォーカスがあるときは
            // 従来どおり Esc で閉じる。
            Button("閉じる") { model.requestClose?() }
                .keyboardShortcut(
                    AnnotationKeyboard.closeButtonOwnsEscape(
                        isEditingText: model.editor.isEditingText,
                        isCanvasFocused: model.editor.isCanvasFocused,
                        hasSelection: !model.editor.document.selectedIDs.isEmpty)
                        ? .cancelAction : nil)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func feedbackBanner(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .padding(.horizontal, Self.barHorizontalPadding)
            .padding(.vertical, Self.barVerticalPadding)
            .glassEffect(in: Capsule())
            .padding(.top, 10)
            .transition(.opacity)
    }
}

/// 赤い塗りつぶし・白文字のボタン（新規キャプチャ）。
///
/// 標準の `.borderedProminent` は使わない。ウィンドウが非アクティブになると色を外して
/// グレーにするため、白文字が背景に溶けて何も見えなくなる。ここでは背景を自前で描き、
/// 非アクティブのときは彩度を少し落とすだけにして、赤いボタンだと分かるまま読めるようにする。
struct FilledRedButtonStyle: ButtonStyle {
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isActive = activeState == .key || activeState == .active
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(Color(nsColor: Self.fillColor(
                    isActive: isActive, isPressed: configuration.isPressed)))
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }

    /// 塗りの色。`.saturation` などのフィルタではなく色そのものを混ぜて作る
    /// （フィルタは描画経路によって効かないことがあり、見た目が環境で変わるため）。
    /// 動的色（systemRed・systemGray）なのでライト・ダークに追従する。
    static func fillColor(isActive: Bool, isPressed: Bool) -> NSColor {
        var color = NSColor.systemRed
        // 非アクティブはグレーを少し混ぜて彩度を落とす（白文字が読める濃さは保つ）。
        if !isActive { color = color.blended(withFraction: 0.35, of: .systemGray) ?? color }
        // 押している間は少し暗くする。
        if isPressed { color = color.blended(withFraction: 0.15, of: .black) ?? color }
        return color
    }
}
