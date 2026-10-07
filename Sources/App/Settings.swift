import Foundation

// 設定。UserDefaults に薄く被せる。
//
// 第 1 版で永続化するのは以下だけ。
// - 直前に使った認識モード（6.3「次回の既定として記憶する」）
// - コピー後にウィンドウを閉じるか（CPY-04、既定は閉じない）
// - 保存先（SAV-04、既定はデスクトップ）
// - 画像を等倍で表示するか（結果ウィンドウのトグル状態）
// - 最後に選んだ保存形式（HEIC / PNG / JPG）
// - 注釈の種類ごとの最後のスタイル（AnnotationStyleStore 経由で JSON）
//
// @Observable にしているのは、設定ウィンドウを開いたまま
// メニューバーからモードを変えても表示が追従するようにするため。
// 値をビューに複製すると「実際の設定と表示がずれる」状態が起きる。
@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    @ObservationIgnored
    private let defaults = UserDefaults.standard

    private enum Key {
        static let recognitionMode = "recognitionMode"
        static let closeAfterCopy = "closeAfterCopy"
        static let saveDirectory = "saveDirectory"
        static let includeWindowShadow = "includeWindowShadow"
        static let actualSize = "actualSize"
        static let exportFormat = "exportFormat"
    }

    /// 直前に使った認識モード。既定は日本語（6.3）。
    var recognitionMode: RecognitionMode {
        didSet { defaults.set(recognitionMode.rawValue, forKey: Key.recognitionMode) }
    }

    /// コピー後にウィンドウを自動で閉じるか（CPY-04）。
    var closeAfterCopy: Bool {
        didSet { defaults.set(closeAfterCopy, forKey: Key.closeAfterCopy) }
    }

    /// 画像の保存先（SAV-01 / SAV-04）。未設定ならデスクトップ。
    var saveDirectory: URL {
        didSet { defaults.set(saveDirectory.path, forKey: Key.saveDirectory) }
    }

    /// ウィンドウキャプチャにドロップシャドウを付けるか（CAP-07）。
    ///
    /// 既定は付ける。資料やブログに貼るときに影付きの方が見栄えがするため。
    /// 影は ShadowCompositor が後から合成するので、オンにしても
    /// ウィンドウ本体の画質は落ちない（実測でピクセル完全一致）。
    var includeWindowShadow: Bool {
        didSet { defaults.set(includeWindowShadow, forKey: Key.includeWindowShadow) }
    }

    /// 結果ウィンドウで画像を等倍（1:1）表示するか（要求 4.3）。
    ///
    /// 既定は等倍。1x ディスプレイでは縮小すると必ずリサンプリングで
    /// ぼやけるため。結果ウィンドウのトグルを操作すると即座にここへ
    /// 書き戻し、次にキャプチャしたときも同じ表示で開く。
    var actualSize: Bool {
        didSet { defaults.set(actualSize, forKey: Key.actualSize) }
    }

    /// 最後に選んだ保存形式（実装計画-HDR P4-5）。既定は PNG（従来どおり）。
    ///
    /// 結果画面で「毎回選ぶ」方針だが、直前の選択は覚えておく。認識モード・等倍表示と同じ
    /// 流儀で、続けて撮るたびに同じ形式を選び直す手間を省くため。設定画面には出さない
    /// （選ぶ場所は結果画面のボタンバーだけ。選択肢は常に見えているので意図しない形式で
    /// 保存してしまう心配は小さい）。
    var exportFormat: ImageExporter.Format {
        didSet { defaults.set(exportFormat.rawValue, forKey: Key.exportFormat) }
    }

    /// 種類ごとの「最後に使った注釈スタイル」の保存先（実装計画 P4-4）。
    /// 注釈エディタ（結果ウィンドウごと）がここから初期値を読み、変更のたびに書き戻す。
    /// Settings の stored property にしない（@Observable で全ビューを無駄に
    /// 再評価させないため。値の保持は AnnotationEditor が持つ）。
    var annotationStyleStore: AnnotationStyleStore {
        AnnotationStyleStore(defaults: defaults)
    }

    private init() {
        // CPY-04 の既定を「閉じない」に変更した（ユーザー要求）。
        //
        // 仕様 CPY-04 は「既定は閉じる（1 アクションで完結させるため）」と
        // していたが、実際に使うと勝手に閉じられる方が邪魔だった。
        // 画像とテキストの両方をコピーしたい、コピーしてから内容を確認したい、
        // といった操作が閉じられると成立しない。閉じるのはユーザーに任せる。
        defaults.register(defaults: [
            Key.closeAfterCopy: false,
            // CAP-07: 影ありを既定にする（ユーザー要求）。
            Key.includeWindowShadow: true,
            // 4.3: 縮小によるぼやけを避けるため等倍を既定にする。
            Key.actualSize: true,
        ])

        // 保存済みの値を読み込む。didSet は init 中には走らないので
        // ここでの代入で UserDefaults へ書き戻されることはない。
        if let raw = defaults.string(forKey: Key.recognitionMode),
           let mode = RecognitionMode(rawValue: raw) {
            recognitionMode = mode
        } else {
            recognitionMode = .japanese
        }
        closeAfterCopy = defaults.bool(forKey: Key.closeAfterCopy)
        includeWindowShadow = defaults.bool(forKey: Key.includeWindowShadow)
        actualSize = defaults.bool(forKey: Key.actualSize)
        exportFormat = defaults.string(forKey: Key.exportFormat)
            .flatMap(ImageExporter.Format.init(rawValue:)) ?? .png
        if let path = defaults.string(forKey: Key.saveDirectory) {
            saveDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            saveDirectory = Self.desktopDirectory
        }
    }

    static var desktopDirectory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop")
    }
}
