import SwiftUI
import UIKit

/// Shows the 240x160 framebuffer. A plain CALayer with nearest-neighbour scaling: for a 150 KB image per frame
/// this is cheap and needs no shaders. (If profiling ever says otherwise, an MTKView is the upgrade path.)
final class GameScreenView: UIView {
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    /// GBA colour correction: the warmer, softer colours a real GBA screen showed (on by default; "..." menu).
    var colorCorrection = true

    /// 15-bit colour (5 bits per channel, all a GBA has) -> corrected RGBX. The usual GBA screen model: linearise,
    /// mix the channels the way the GBA panel bled them, dim slightly, re-encode for the phone's screen.
    private static let correction: [UInt32] = (0..<32768).map { i in
        let r = pow(Double(i & 31) / 31, 2.2), g = pow(Double((i >> 5) & 31) / 31, 2.2), b = pow(Double(i >> 10) / 31, 2.2)
        func out(_ v: Double) -> UInt32 { UInt32((pow(min(max(v * 0.94, 0), 1), 1 / 2.2) * 255).rounded()) }
        let cr = out(0.82 * r + 0.125 * g + 0.195 * b)
        let cg = out(0.24 * r + 0.665 * g + 0.075 * b)
        let cb = out(-0.06 * r + 0.21 * g + 0.73 * b)
        return cr | cg << 8 | cb << 16 | 0xFF00_0000
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        layer.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// `pixels` is 240*160 four-byte pixels in memory order R,G,B,X (what mGBA writes without COLOR_16_BIT).
    func present(pixels: UnsafePointer<UInt32>) {
        let count = MGBACore.width * MGBACore.height * 4
        // Copy: mGBA overwrites its buffer during the next frame, possibly before Core Animation has used this one.
        var data: Data
        if colorCorrection {
            data = Data(count: count)
            data.withUnsafeMutableBytes { raw in
                let out = raw.bindMemory(to: UInt32.self)
                Self.correction.withUnsafeBufferPointer { lut in
                    for i in 0..<(MGBACore.width * MGBACore.height) {
                        let p = pixels[i] // R, G, B, X in memory: R in the low byte
                        out[i] = lut[Int((p >> 3) & 31) | Int((p >> 11) & 31) << 5 | Int((p >> 19) & 31) << 10]
                    }
                }
            }
        } else {
            data = Data(bytes: pixels, count: count)
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let image = CGImage(
            width: MGBACore.width,
            height: MGBACore.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: MGBACore.width * 4,
            space: colorSpace,
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return }
        layer.contents = image
    }

    func clear() {
        layer.contents = nil
    }
}

struct GameScreen: UIViewRepresentable {
    let emulator: Emulator
    var colorCorrection = true

    func makeUIView(context: Context) -> GameScreenView {
        let view = GameScreenView()
        view.colorCorrection = colorCorrection
        emulator.screen = view
        return view
    }

    func updateUIView(_ uiView: GameScreenView, context: Context) {
        uiView.colorCorrection = colorCorrection
        emulator.screen = uiView
    }
}
