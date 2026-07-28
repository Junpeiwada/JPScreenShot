import Foundation

// 環境設定。UserDefaults に薄く被せる。
//
// 第 1 版で永続化するのは以下だけ。
// - 直前に使った認識モード（6.3「次回の既定として記憶する」）
// - コピー後にウィンドウを閉じるか（CPY-04、既定は閉じない）
// - 保存先（SAV-04、既定はデスクトップ）
//
// @Observable にしているのは、環境設定ウィンドウを開いたまま
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

    private init() {
        // CPY-04 の既定を「閉じない」に変更した（ユーザー要求）。
        //
        // 仕様 CPY-04 は「既定は閉じる（1 アクションで完結させるため）」と
        // していたが、実際に使うと勝手に閉じられる方が邪魔だった。
        // 画像とテキストの両方をコピーしたい、コピーしてから内容を確認したい、
        // といった操作が閉じられると成立しない。閉じるのはユーザーに任せる。
        defaults.register(defaults: [Key.closeAfterCopy: false])

        // 保存済みの値を読み込む。didSet は init 中には走らないので
        // ここでの代入で UserDefaults へ書き戻されることはない。
        if let raw = defaults.string(forKey: Key.recognitionMode),
           let mode = RecognitionMode(rawValue: raw) {
            recognitionMode = mode
        } else {
            recognitionMode = .japanese
        }
        closeAfterCopy = defaults.bool(forKey: Key.closeAfterCopy)
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
