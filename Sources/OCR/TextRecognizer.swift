import CoreGraphics
import Vision

// Vision による文字認識（要求 5.2）。
//
// 実装計画 1.1 のとおり、新 API の `RecognizeTextRequest`（Sendable な
// 構造体・async）を使う。旧 `VNRecognizeTextRequest` は参照型のため
// Swift 6 の厳格並行モードで隔離の扱いが煩雑になる。
// 認識エンジンは revision3 で旧 API と同一であり、実測精度は変わらない。
enum TextRecognizer {

    /// 認識結果。
    struct Result: Sendable {
        /// 行の並び順を保って改行区切りで組み立てたテキスト（OCR-04）。
        let text: String
        /// 認識できた行数。0 なら「認識できませんでした」の表示に使う（4.3）。
        let lineCount: Int
    }

    /// 画像から文字を認識する。
    ///
    /// この関数は `nonisolated` なので、呼び出し側の `await` によって
    /// メインスレッドを離れて実行される。UI をブロックしない
    /// （非機能要求・応答性 / OCR-01）。
    static func recognize(
        image: CGImage,
        mode: RecognitionMode
    ) async throws -> Result {
        var request = RecognizeTextRequest()
        // OCR-02: .fast は日本語で実用に耐えないため必ず .accurate。
        request.recognitionLevel = .accurate
        // OCR-03: 認識言語を明示する。指定しないと英語として誤認識される。
        request.recognitionLanguages = mode.recognitionLanguages
        request.usesLanguageCorrection = mode.usesLanguageCorrection

        let observations = try await request.perform(on: image)

        // OCR-04: 行の並び順を保って改行区切りで組み立てる。
        //
        // observations は認識順で返るが、保証された順序ではないため
        // 読み順（上から下、同じ高さなら左から右）に並べ直す。
        let sorted = observations.sorted { lhs, rhs in
            let l = lhs.boundingBox.cgRect
            let r = rhs.boundingBox.cgRect
            // Vision の正規化座標は下が 0 なので、maxY が大きいほど上の行。
            // 行の高さ程度の差は「同じ行」と見なして左右で比較する。
            let threshold = max(l.height, r.height) * 0.5
            if abs(l.midY - r.midY) > threshold {
                return l.midY > r.midY
            }
            return l.minX < r.minX
        }

        // Vision は 1 行の文章を複数の観測に分割して返すことがある
        // （実測: 「…ピクセル」と「であり、…」が別の観測になった）。
        // そのまま改行で連結すると本文に無い改行が入るため、
        // 縦方向に重なっている観測は同じ行として横に連結する。
        var lines: [String] = []
        var previousRect: CGRect?

        for observation in sorted {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let rect = observation.boundingBox.cgRect

            if let previous = previousRect, !lines.isEmpty,
               Self.isSameLine(previous, rect) {
                // 同じ行の続き。日本語は単語区切りに空白を使わないので
                // そのまま連結する。
                lines[lines.count - 1] += candidate.string
                // 行の範囲を広げて、3 つ以上に分割された場合にも対応する。
                previousRect = previous.union(rect)
            } else {
                lines.append(candidate.string)
                previousRect = rect
            }
        }

        let text = lines.joined(separator: "\n")

        // OCR-05 / 6.3: コードモードでは全角→半角の正規化を行う。
        let finalText = mode.needsCodeNormalization
            ? CodeNormalizer.normalize(text)
            : text

        return Result(text: finalText, lineCount: lines.count)
    }

    /// 2 つの観測が同じ視覚的な行に属するか判定する。
    ///
    /// 縦方向の重なりが行の高さに対して十分大きければ同じ行と見なす。
    /// 行間が狭い文章で隣の行を巻き込まないよう、閾値は高めに取る。
    private static func isSameLine(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        guard overlap > 0 else { return false }
        let smallerHeight = min(a.height, b.height)
        guard smallerHeight > 0 else { return false }
        return overlap / smallerHeight > 0.6
    }
}
