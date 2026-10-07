import Foundation

/// 書き出し（保存・コピー）の失敗。黙って SDR に落とさず、利用者へ理由を伝えるために型を分ける。
enum ExportError: Error, Equatable {
    /// HDR を求められたが HDR 版の画像が無い。
    case hdrImageMissing
    /// SDR 版と HDR 版でピクセル寸法が違う（ゲインマップを作れない）。
    case sizeMismatch
    /// Metal カーネル（metallib）を読めなかった。ゲインマップを作れない。
    case kernelUnavailable
    /// 3ch カラーゲインマップの生成・添付に失敗した（補助辞書を作れない・書いた結果が 1ch だった）。
    case colorGainMapFailed
    /// 書き出し後の検算でゲインマップが入っていなかった（JPEG / HEIC）。
    case gainMapVerificationFailed
    /// 画像の変換（CIImage → CGImage、色空間の変換）に失敗した。
    case imageConversionFailed
    /// エンコーダ（ImageIO / CoreImage）が失敗した。
    case encodingFailed(String)
}

extension ExportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .hdrImageMissing:
            return "HDR 版の画像がありません"
        case .sizeMismatch:
            return "SDR 版と HDR 版の大きさが一致しません"
        case .kernelUnavailable:
            return "ゲインマップ用の Metal カーネルを読み込めませんでした（アプリのビルドに問題があります）"
        case .colorGainMapFailed:
            return "カラーゲインマップを生成できませんでした"
        case .gainMapVerificationFailed:
            return "書き出した画像にゲインマップが入っていませんでした"
        case .imageConversionFailed:
            return "画像を変換できませんでした"
        case .encodingFailed(let what):
            return "\(what) の書き出しに失敗しました"
        }
    }
}
