import Foundation

// 環境設定。UserDefaults に薄く被せる。
//
// 第 1 版で永続化するのは以下だけ。
// - 直前に使った認識モード（6.3「次回の既定として記憶する」）
// - コピー後にウィンドウを閉じるか（CPY-04、既定は閉じる）
// - 保存先（SAV-04、既定はデスクトップ）
@MainActor
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let recognitionMode = "recognitionMode"
        static let closeAfterCopy = "closeAfterCopy"
        static let saveDirectory = "saveDirectory"
    }

    private init() {
        // CPY-04: 既定は「閉じる」。1 アクションで完結させるため。
        defaults.register(defaults: [Key.closeAfterCopy: true])
    }

    /// 直前に使った認識モード。既定は日本語（6.3）。
    var recognitionMode: RecognitionMode {
        get {
            guard let raw = defaults.string(forKey: Key.recognitionMode),
                  let mode = RecognitionMode(rawValue: raw)
            else { return .japanese }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Key.recognitionMode) }
    }

    /// コピー後にウィンドウを自動で閉じるか（CPY-04）。
    var closeAfterCopy: Bool {
        get { defaults.bool(forKey: Key.closeAfterCopy) }
        set { defaults.set(newValue, forKey: Key.closeAfterCopy) }
    }

    /// 画像の保存先（SAV-01 / SAV-04）。未設定ならデスクトップ。
    var saveDirectory: URL {
        get {
            if let path = defaults.string(forKey: Key.saveDirectory) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return Self.desktopDirectory
        }
        set { defaults.set(newValue.path, forKey: Key.saveDirectory) }
    }

    static var desktopDirectory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop")
    }
}
