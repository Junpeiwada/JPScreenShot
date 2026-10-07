import AppKit
import CoreGraphics
import Foundation
import Observation

/// 表示・書き出しの下敷きにする画像の種類（SDR 版か HDR 版か）。
enum ImageDynamicRange: Sendable {
    case sdr
    case hdr
}

// 結果ウィンドウ 1 枚分の注釈編集の状態。
//
// 注釈の配列・選択・取り消し（AnnotationDocument）、ぼかしのキャッシュ
// （RedactionRenderer）、いま選んでいるツール、種類ごとの「最後に使ったスタイル」を
// まとめて持つ。ResultViewModel が 1 つ持ち、キャンバス・ツールレール・
// スタイルのポップオーバーが共有する。
@MainActor
@Observable
final class AnnotationEditor {

    let document = AnnotationDocument()

    /// SDR 版・HDR 版それぞれの加工キャッシュ。ウィンドウごとに最大 2 つ。
    ///
    /// レンダラは「ベース画像ごとのインスタンス」で、キャッシュは自分のベースから作った画像だけを
    /// 持つ。SDR と HDR で 1 つを使い回すと 8bit と 16bit float が混ざるので、2 つ持って
    /// `dynamicRange` で選ぶ。切り替えても注釈（`document`）は同じものを共有するので、
    /// 位置・見た目は変わらない（両版は同じピクセル寸法）。
    ///
    /// HDR 側は初めて必要になったときに作る（遅延生成）。HDR 版がある撮影は既定が HDR なので、
    /// 実際には結果画面を開いてすぐ作られる。HDR 版が無い撮影（SDR のみの環境）では作らず、
    /// Retina の 16bit float 用の CIContext とキャッシュを確保しない。
    @ObservationIgnored private let sdrRedaction: RedactionRenderer
    @ObservationIgnored private var hdrRedactionStorage: RedactionRenderer?
    /// HDR 版の元画像（寸法が SDR と一致したときだけ持つ）。`hdrRedactionStorage` の元。
    @ObservationIgnored private let hdrBase: CGImage?
    @ObservationIgnored private let scale: CGFloat

    /// いま下敷きにしている版。フェーズ3の SDR/HDR 切替が書き換える。
    /// HDR 版が無いのに `.hdr` にはできない（`.sdr` のまま）。
    var dynamicRange: ImageDynamicRange = .sdr {
        didSet { if dynamicRange == .hdr, hdrRedaction == nil { dynamicRange = .sdr } }
    }

    /// HDR 版の加工レンダラ。初回アクセスで作る。HDR 版が無ければ nil。
    private var hdrRedaction: RedactionRenderer? {
        if hdrRedactionStorage == nil, let hdrBase {
            hdrRedactionStorage = RedactionRenderer(base: hdrBase, scale: scale)
        }
        return hdrRedactionStorage
    }

    /// 両版のキャッシュから、`ids` に含まれない注釈ぶんを捨てる。
    /// 表示中でない版も掃除しないと、切替後に消えた注釈のキャッシュが残る。
    func pruneRedactions(keeping ids: Set<UUID>) {
        sdrRedaction.prune(keeping: ids)
        hdrRedactionStorage?.prune(keeping: ids)
    }

    /// HDR 版の下敷きがあるか。
    var hasHDR: Bool { hdrBase != nil }

    /// HDR 版の元画像（寸法が SDR と一致したときだけ非 nil）。表示用。
    var hdrImage: CGImage? { hdrBase }

    /// いまの版の加工レンダラ。キャンバスの描画は毎回これを引く（切替で差し替わる）。
    var redaction: RedactionRenderer {
        dynamicRange == .hdr ? (hdrRedaction ?? sdrRedaction) : sdrRedaction
    }

    /// 現在のツール。既定は選択（撮ってすぐコピーする今までの使い方を変えない）。
    var tool: AnnotationTool = .select

    /// テキストを入力中か。入力中は `Esc` を「閉じる」ボタンに取られないよう、
    /// ResultView が参照する（`Esc` は入力の確定に使う）。
    var isEditingText = false

    /// キャンバスが first responder か。`Esc` の行き先（選択解除か「閉じる」か）を
    /// ResultView が決めるために参照する。OCR テキスト欄にフォーカスがあれば false。
    var isCanvasFocused = false

    /// 種類ごとの最後のスタイル。新規作成の初期値で、レールやポップオーバーで
    /// 選択中を変えたときも、その種類の分を更新する（実装計画 P4-4）。
    private(set) var lastStyles: [AnnotationKind: AnnotationStyle] = [:]

    @ObservationIgnored private let styleStore: AnnotationStyleStore

    /// テキスト入力を確定させる処理。キャンバスが登録する。
    /// コピー・保存・ツール切り替えの前に呼んで、入力途中の文字を取りこぼさない。
    @ObservationIgnored var textEditingFinisher: (@MainActor () -> Void)?

    // スライダーのドラッグ中か（履歴を積まずに書き換える）。
    @ObservationIgnored private var isContinuousChange = false
    // ColorPicker など「連続して値が変わるが開始・終了が分からない」操作を 1 回の
    // 取り消しにまとめるための状態。
    @ObservationIgnored private var coalescing: Coalescing?

    private struct Coalescing {
        let key: String
        let ids: Set<UUID>
        let undoCount: Int
        let date: Date
    }

    /// - Parameters:
    ///   - base: SDR 版の元画像。
    ///   - hdrBase: HDR 版の元画像。`base` と同じピクセル寸法のときだけ使う
    ///     （寸法が違うと加工範囲がずれるので、無視して SDR のみにする）。
    ///   - styleStore: 最後のスタイルの保存先。既定は設定。
    init(
        base: CGImage, scale: CGFloat, hdrBase: CGImage? = nil,
        styleStore: AnnotationStyleStore? = nil
    ) {
        self.sdrRedaction = RedactionRenderer(base: base, scale: scale)
        self.scale = scale
        if let hdrBase, hdrBase.width == base.width, hdrBase.height == base.height {
            self.hdrBase = hdrBase
        } else {
            self.hdrBase = nil
        }
        let store = styleStore ?? Settings.shared.annotationStyleStore
        self.styleStore = store
        // 起動時に全種類ぶん読んで保持する。新規作成のドラッグ中に毎回 JSON を
        // デコードしないため。
        let saved = store.loadAll()
        for kind in AnnotationKind.allCases {
            lastStyles[kind] = saved[kind] ?? .initialStyle(for: kind)
        }
    }

    /// ポップオーバーなど、キャンバスの外に出している一時的な UI を閉じる処理。
    /// キャンバスが登録する。
    @ObservationIgnored var transientUIDismisser: (@MainActor () -> Void)?

    /// キャンバスにキーボードフォーカスを戻す処理。キャンバスが登録する。
    /// 小窓の数値欄で Return を押したあとなど、⌫・矢印・ツールキーをすぐ効かせるために呼ぶ。
    @ObservationIgnored var canvasFocuser: (@MainActor () -> Void)?

    /// ウィンドウを閉じるときの解放（Retina の大きな画像ではキャッシュが重い）。
    func tearDown() {
        finishTextEditing()
        endContinuousStyleChange()
        flushStyles()
        dismissTransientUI()
        document.removeAll()
        sdrRedaction.removeAllCachedImages()  // CIContext のキャッシュも捨てる
        hdrRedactionStorage?.removeAllCachedImages()
        textEditingFinisher = nil
        transientUIDismisser = nil
        canvasFocuser = nil
    }

    /// ポップオーバーとカラーパネルを閉じる。ウィンドウを閉じる・隠すときに呼ぶ。
    /// （開いたままだと、隠れたウィンドウの選択に色の変更が効いてしまう。）
    func dismissTransientUI() {
        endContinuousStyleChange()
        transientUIDismisser?()
        // 自分が宛先のときだけ、パネルの宛先を外してから閉じる。
        ColorPanelBridge.detach(for: self)
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
    }

    // MARK: ツール・テキスト入力

    /// ツールを切り替える。入力途中のテキストは先に確定する。
    func selectTool(_ tool: AnnotationTool) {
        finishTextEditing()
        self.tool = tool
    }

    /// 入力途中のテキストがあれば確定する。
    func finishTextEditing() {
        textEditingFinisher?()
    }

    // MARK: スタイル（最後に使った値）

    /// 新規作成する注釈の初期スタイル。その種類の最後のスタイル。
    func style(for kind: AnnotationKind) -> AnnotationStyle {
        lastStyles[kind] ?? .initialStyle(for: kind)
    }

    /// レールの色・太さが「選択中」ではなく「次に描くもの」に効くときの対象の種類。
    /// 描画ツール中はそのツールの種類だけ。選択ツールで何も選んでいなければ全種類
    /// （色を選んでから描画ツールへ切り替えても、選んだ色で描けるように）。
    /// テキストは含めない。白文字・黒縁の袋文字が既定で、図形の色を選んだだけで
    /// 文字色まで変わると意図しないため。
    private var kindsForNextDrawing: [AnnotationKind] {
        if let kind = tool.kind { return [kind] }
        return AnnotationKind.allCases.filter { $0 != .text }
    }

    /// 保存待ちの種類。スライダーの連続操作で毎回 JSON を読み書きしないよう、
    /// メモリ上の `lastStyles` だけ更新し、保存は少し待ってまとめて行う。
    @ObservationIgnored private var unsavedKinds: Set<AnnotationKind> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private func remember(_ style: AnnotationStyle, for kind: AnnotationKind) {
        lastStyles[kind] = style
        unsavedKinds.insert(kind)
        // 連続操作中は終了時（endContinuousStyleChange）にまとめて保存する。
        guard !isContinuousChange else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.flushStyles()
        }
    }

    /// 保存待ちのスタイルをいま保存する。ウィンドウを閉じるとき・連続操作の終了時・テストから。
    func flushStyles() {
        saveTask?.cancel()
        saveTask = nil
        guard !unsavedKinds.isEmpty else { return }
        var all = styleStore.loadAll()
        for kind in unsavedKinds { all[kind] = lastStyles[kind] }
        unsavedKinds.removeAll()
        styleStore.saveAll(all)
    }

    /// 選択中の注釈のスタイルを、その種類の最後のスタイルとして覚える。
    private func rememberStylesOfSelection() {
        var seen: Set<AnnotationKind> = []
        for annotation in document.selectedAnnotations where !seen.contains(annotation.kind) {
            seen.insert(annotation.kind)
            remember(annotation.style, for: annotation.kind)
        }
    }

    // MARK: スタイルの変更

    /// スタイルを変える。選択中があればそれらに（取り消し 1 回分）、無ければ
    /// 「次に描くもの」の最後のスタイルに効く。どちらも種類ごとの最後のスタイルを更新する。
    ///
    /// - Parameters:
    ///   - coalescing: 連続して呼ばれる操作（カラーパネルのドラッグなど）を 1 回の
    ///     取り消しにまとめるときのキー。同じキーが一定時間内に続けば履歴を積まない。
    ///   - change: スタイルの書き換え。第 2 引数は対象の種類。
    func updateStyle(
        coalescing key: String? = nil,
        _ change: @escaping (inout AnnotationStyle, AnnotationKind) -> Void
    ) {
        let ids = document.selectedIDs
        guard !ids.isEmpty else {
            for kind in kindsForNextDrawing {
                var style = style(for: kind)
                change(&style, kind)
                remember(style, for: kind)
            }
            return
        }

        let transform: (inout Annotation) -> Void = { annotation in
            change(&annotation.style, annotation.kind)
        }
        if isContinuousChange {
            document.mutateWithoutHistory(ids: ids, transform)
        } else if let key, canCoalesce(key: key, ids: ids) {
            document.mutateWithoutHistory(ids: ids, transform)
            coalescing = Coalescing(
                key: key, ids: ids, undoCount: document.undoStack.count, date: Date())
        } else {
            let before = document.undoStack.count
            document.mutate(ids: ids, transform)
            // 履歴が積まれた（実際に変わった）ときだけ、続く操作をまとめる対象にする。
            coalescing =
                key.flatMap { key in
                    document.undoStack.count > before
                        ? Coalescing(
                            key: key, ids: ids, undoCount: document.undoStack.count, date: Date())
                        : nil
                }
        }
        rememberStylesOfSelection()
    }

    private func canCoalesce(key: String, ids: Set<UUID>) -> Bool {
        guard let coalescing else { return false }
        return coalescing.key == key && coalescing.ids == ids
            && coalescing.undoCount == document.undoStack.count
            && document.redoStack.isEmpty
            && Date().timeIntervalSince(coalescing.date) < 1.5
    }

    /// スライダーのドラッグ開始。選択中の変更を 1 回の取り消しにまとめるため、
    /// ここで履歴を 1 回だけ積み、終了までは履歴なしで書き換える。
    func beginContinuousStyleChange() {
        guard !document.selectedIDs.isEmpty, !isContinuousChange else { return }
        document.beginChange()
        isContinuousChange = true
        continuousIDs = document.selectedIDs
        coalescing = nil
    }

    /// 連続操作を始めたときの選択。選択が変わったら連続操作を終わらせる判断に使う。
    @ObservationIgnored private var continuousIDs: Set<UUID> = []

    /// 選択が変わったとき（キャンバスが呼ぶ）。スライダーの「離した」通知が届かなくても、
    /// 連続操作が固まって次の選択へ履歴なしの書き換えが続かないようにする。
    func selectionDidChange() {
        if isContinuousChange, document.selectedIDs != continuousIDs {
            endContinuousStyleChange()
        }
    }

    /// スライダーのドラッグ終了。何も変わっていなければ履歴を戻す。
    func endContinuousStyleChange() {
        guard isContinuousChange else { return }
        isContinuousChange = false
        document.commitChange()
        // 連続操作中は保存を止めていたので、ここで保存する。
        if !unsavedKinds.isEmpty { flushStyles() }
    }

    /// 種類を切り替える（矢印⇔線⇔四角⇔円、ぼかし⇔モザイク）。取り消し 1 回分。
    func changeKind(to kind: AnnotationKind) {
        document.changeKind(to: kind)
        coalescing = nil
        rememberStylesOfSelection()
    }

    // MARK: レールの色・太さ

    /// 色・太さの表示と操作の対象にする注釈。選択中があればそれ。
    private var selected: [Annotation] { document.selectedAnnotations }

    /// レールに出す現在の色。選択中があればその色（テキストは文字色）、
    /// 無ければ次に描くものの色。効く対象がなければ nil。
    var displayedColor: RGBAColor? {
        if !selected.isEmpty {
            return selected.lazy.compactMap {
                AnnotationStyleEditing.color(of: $0.style, kind: $0.kind)
            }.first
        }
        let kind = tool.kind ?? .arrow
        return AnnotationStyleEditing.color(of: style(for: kind), kind: kind)
    }

    /// レールに出す現在の太さ。
    var displayedLineWidth: Double? {
        if !selected.isEmpty {
            return selected.first { AnnotationStyleEditing.supportsLineWidth($0.kind) }?.style.lineWidth
        }
        let kind = tool.kind ?? .arrow
        return AnnotationStyleEditing.supportsLineWidth(kind) ? style(for: kind).lineWidth : nil
    }

    /// 色を変えられるか（選択中に色を持つものがある／次に描く種類が色を持つ）。
    var canChangeColor: Bool {
        if !selected.isEmpty { return selected.contains { AnnotationStyleEditing.supportsColor($0.kind) } }
        return tool.kind.map(AnnotationStyleEditing.supportsColor) ?? true
    }

    /// 太さを変えられるか。
    var canChangeLineWidth: Bool {
        if !selected.isEmpty {
            return selected.contains { AnnotationStyleEditing.supportsLineWidth($0.kind) }
        }
        return tool.kind.map(AnnotationStyleEditing.supportsLineWidth) ?? true
    }

    /// 色を変える（レールのプリセット・カラーパネル）。
    func setColor(_ color: RGBAColor, coalescing key: String? = nil) {
        // 入力途中のテキストがあれば先に確定し、その文字に色が効くようにする。
        finishTextEditing()
        updateStyle(coalescing: key) { style, kind in
            style = AnnotationStyleEditing.setting(color: color, on: style, kind: kind)
        }
    }

    /// ColorPicker（カラーパネル）からの変更を受け付けるか。
    ///
    /// カラーパネルを開いたまま別の注釈を選ぶと、SwiftUI がパネルへ新しい選択の色を
    /// 流し込む前後に、前の選択の色が `set` として届きうる。それを新しい選択へ適用して
    /// しまわないよう、(1) 対象の全員がすでに同じ色なら何もしない、(2) 選択が変わった直後の
    /// 変更は無視する。ユーザーが操作して変えた色だけを通す。
    func acceptsPickerColor(_ color: RGBAColor, currentColors: [RGBAColor]) -> Bool {
        AnnotationStyleEditing.shouldAcceptPickerColor(
            color, currentColors: currentColors,
            secondsSinceSelectionChange: Date().timeIntervalSince(document.selectionChangedAt))
    }

    /// 色の操作の対象すべての現在の色。選択中なら色を持つ全員、無ければ次に描くものの色。
    var displayedColors: [RGBAColor] {
        if !selected.isEmpty {
            return selected.compactMap { AnnotationStyleEditing.color(of: $0.style, kind: $0.kind) }
        }
        return displayedColor.map { [$0] } ?? []
    }

    /// 線の太さを変える（レールの 3 段階）。
    func setLineWidth(_ width: Double) {
        finishTextEditing()
        updateStyle { style, kind in
            style = AnnotationStyleEditing.setting(lineWidth: width, on: style, kind: kind)
        }
    }
}

extension AnnotationStyle {
    /// 新規作成の既定スタイル。赤 #FF3B30・太さ 5・影あり。
    static var initialDrawingStyle: AnnotationStyle {
        var style = AnnotationStyle()
        style.color = RGBAColor(red: 1.0, green: 0x3B / 255, blue: 0x30 / 255)
        style.lineWidth = 5
        style.shadow.isOn = true
        return style
    }
}
