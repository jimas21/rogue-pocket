import SwiftUI
import UIKit

/// Shows the 240x160 framebuffer. A plain CALayer with nearest-neighbour scaling: for a 150 KB image per frame
/// this is cheap and needs no shaders. (If profiling ever says otherwise, an MTKView is the upgrade path.)
final class GameScreenView: UIView {
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

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
        let data = Data(bytes: pixels, count: count)
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

    func makeUIView(context: Context) -> GameScreenView {
        let view = GameScreenView()
        emulator.screen = view
        return view
    }

    func updateUIView(_ uiView: GameScreenView, context: Context) {
        emulator.screen = uiView
    }
}
