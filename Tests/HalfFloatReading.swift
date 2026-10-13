import Accelerate
import CoreGraphics

/// 16bit float（half）の画素を Float で読む。
///
/// `Float16` は x86_64 の macOS では使えない（Intel Mac でテストがビルドできない）ため、
/// 半精度から単精度への変換は vImage に任せる。
func readHalf(_ context: CGContext, component index: Int) -> Float {
    var half = context.data!.load(fromByteOffset: index * 2, as: UInt16.self)
    var value: Float = 0
    withUnsafeMutablePointer(to: &half) { src in
        withUnsafeMutablePointer(to: &value) { dst in
            var srcBuffer = vImage_Buffer(data: src, height: 1, width: 1, rowBytes: 2)
            var dstBuffer = vImage_Buffer(data: dst, height: 1, width: 1, rowBytes: 4)
            _ = vImageConvert_Planar16FtoPlanarF(&srcBuffer, &dstBuffer, 0)
        }
    }
    return value
}
