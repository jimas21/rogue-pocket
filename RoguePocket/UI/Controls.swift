import SwiftUI
import UIKit

/// A button that is "down" for exactly as long as a finger is on it. Separate views get separate touches,
/// so A and B (or L and a direction) can be held together.
struct HoldButton: View {
    let label: String
    let keys: GBAKeys
    let emulator: Emulator
    var width: CGFloat = 56
    var height: CGFloat = 56
    var round = true

    @State private var down = false

    var body: some View {
        Text(label)
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: round ? height / 2 : 12)
                    .fill(down ? Color.accentColor : Color.white.opacity(0.22))
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !down {
                            down = true
                            emulator.setTouch(keys, down: true)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
                    .onEnded { _ in
                        down = false
                        emulator.setTouch(keys, down: false)
                    }
            )
    }
}

/// One touch surface: the direction follows the thumb, so it can slide from Up to Right without lifting.
/// Dominant axis only (4-way), which is what Pokemon uses.
struct DPad: View {
    let emulator: Emulator
    var side: CGFloat = 150

    @State private var active: GBAKeys = []

    var body: some View {
        ZStack {
            arm(.up, dx: 0, dy: -side / 3.2, w: side / 3, h: side / 2.6)
            arm(.down, dx: 0, dy: side / 3.2, w: side / 3, h: side / 2.6)
            arm(.left, dx: -side / 3.2, dy: 0, w: side / 2.6, h: side / 3)
            arm(.right, dx: side / 3.2, dy: 0, w: side / 2.6, h: side / 3)
            Circle().fill(Color.white.opacity(0.10)).frame(width: side / 4, height: side / 4)
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in update(to: direction(at: value.location)) }
                .onEnded { _ in update(to: []) }
        )
    }

    private func arm(_ key: GBAKeys, dx: CGFloat, dy: CGFloat, w: CGFloat, h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(active == key ? Color.accentColor : Color.white.opacity(0.22))
            .frame(width: w, height: h)
            .offset(x: dx, y: dy)
    }

    private func direction(at point: CGPoint) -> GBAKeys {
        let dx = point.x - side / 2
        let dy = point.y - side / 2
        if max(abs(dx), abs(dy)) < side * 0.12 { return [] } // dead zone
        if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
        return dy > 0 ? .down : .up
    }

    private func update(to next: GBAKeys) {
        guard next != active else { return }
        emulator.setTouch(active, down: false)
        emulator.setTouch(next, down: true)
        if !next.isEmpty { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        active = next
    }
}
