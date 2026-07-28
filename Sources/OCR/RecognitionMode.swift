import Foundation

// 認識モード。要求仕様 6.3 の表をそのまま型にしたもの。
//
// | モード | 認識言語 | 言語補正 | 後処理 |
// |---|---|---|---|
// | 日本語（既定） | ja-JP, en-US | on | なし |
// | コード | en-US | off | 全角→半角の正規化 |
enum RecognitionMode: String, CaseIterable, Sendable {
    case japanese
    case code

    var displayName: String {
        switch self {
        case .japanese: "日本語"
        case .code: "コード"
        }
    }

    /// Vision に渡す認識言語。
    var recognitionLanguages: [Locale.Language] {
        switch self {
        case .japanese:
            [Locale.Language(identifier: "ja-JP"), Locale.Language(identifier: "en-US")]
        case .code:
            // 日本語を候補から外すことで記号の全角化を抑える狙い（6.3）。
            [Locale.Language(identifier: "en-US")]
        }
    }

    /// 言語補正。コードでは文脈補正が害になるため off。
    var usesLanguageCorrection: Bool {
        switch self {
        case .japanese: true
        case .code: false
        }
    }

    /// 認識後に全角→半角の正規化を行うか。
    var needsCodeNormalization: Bool {
        switch self {
        case .japanese: false
        case .code: true
        }
    }
}
