import CoreImage
import Foundation

// `Kernels/*.metal` から Xcode がビルド時に作る `default.metallib`（アプリの Resources）から
// Core Image のカーネルを取り出す。HDRForge の同名ファイルの移植（Bundle.module → Bundle）。
//
// - カーネル名は `.metal` の関数名そのもの（`extern "C"` で名前修飾を止めてある）。
// - 読めなかったら理由を標準エラーへ出して nil を返す。呼び出し側は nil を
//   `ExportError.kernelUnavailable` に変えて利用者へ伝える（黙って SDR へ落とさない）。
enum MetalKernelLibrary {

    /// このモジュールの Bundle を引くための目印。
    ///
    /// `Bundle.main` ではなく `Bundle(for:)` を使う。アプリ本体では同じ Bundle だが、
    /// テスト（ホストアプリ付き）でも metallib の入ったアプリ側を確実に指せる。
    private final class BundleToken {}

    /// metallib の中身。一度だけ読む（カーネルごとに読み直さない）。
    static let data: Data? = {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: "default", withExtension: "metallib") else {
            report("default.metallib がバンドルに無い（\(bundle.bundlePath)）。.metal がビルドされていない")
            return nil
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            report("default.metallib を読めない: \(error)")
            return nil
        }
    }()

    static func colorKernel(_ name: String) -> CIColorKernel? {
        guard let data else { return nil }
        do {
            return try CIColorKernel(functionName: name, fromMetalLibraryData: data)
        } catch {
            report("カーネル \(name) を作れない: \(error)")
            return nil
        }
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data("[MetalKernelLibrary] \(message)\n".utf8))
    }
}
