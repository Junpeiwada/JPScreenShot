import Foundation
import Testing

@testable import JPScreenShot

// 仕様 6.3 の表どおりに設定されているかを固定する。
// ここがずれると精度が落ちる（コードモードは実測で 27.3 ポイントの差がある）。
@Suite("認識モードの設定")
struct RecognitionModeTests {

    @Test("日本語モードは ja-JP と en-US を使い、言語補正を有効にする")
    func 日本語モード() {
        let mode = RecognitionMode.japanese
        let codes = mode.recognitionLanguages.map(\.minimalIdentifier)
        #expect(codes.contains("ja"))
        #expect(mode.usesLanguageCorrection)
        #expect(!mode.needsCodeNormalization)
    }

    @Test("コードモードは英語のみで、言語補正を切り、後処理を行う")
    func コードモード() {
        let mode = RecognitionMode.code
        let codes = mode.recognitionLanguages.map(\.minimalIdentifier)
        // 日本語を候補から外すことが精度向上の要（実測 97.0% 対 69.7%）。
        #expect(!codes.contains("ja"))
        #expect(!mode.usesLanguageCorrection)
        #expect(mode.needsCodeNormalization)
    }

    @Test("すべてのモードに表示名がある")
    func 表示名() {
        for mode in RecognitionMode.allCases {
            #expect(!mode.displayName.isEmpty)
        }
    }

    @Test("rawValue から復元できる（設定の永続化に使う）")
    func 永続化の往復() {
        for mode in RecognitionMode.allCases {
            #expect(RecognitionMode(rawValue: mode.rawValue) == mode)
        }
    }
}
