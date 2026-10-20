import SwiftUI

/// Draws the battle overlay over the game picture. Everything is placed in GBA pixels and scaled with the picture,
/// so it lines up in portrait and landscape alike, and it sits only on empty background or blank menu space.
struct BattleOverlayView: View {
    @ObservedObject var overlay: BattleOverlay

    /// Where each move's name starts in the move menu, and the free row under it.
    private static let moveSlots = [CGPoint(x: 16, y: 134), CGPoint(x: 88, y: 134),
                                    CGPoint(x: 16, y: 151), CGPoint(x: 88, y: 151)]
    /// The weakness row must end before the enemy's sprite (which starts at x 144).
    private static let weaknessRowEnd: CGFloat = 143
    /// The switch screen: the first member's big card (its free spot is just above the card), then the free gap in
    /// the second row of each of the five slots on the right.
    private static let partySlots = [CGPoint(x: 60, y: 17)] + (0..<5).map { CGPoint(x: 165, y: 26 + 24 * CGFloat($0)) }

    var body: some View {
        Canvas { ctx, size in
            guard let state = overlay.state else { return }
            let s = size.width / 240
            if state.partyMenu {
                // The switch screen: its top left is empty background.
                drawWeaknesses(state.weaknesses, at: CGPoint(x: 4, y: 3), icon: 8, ctx: ctx, s: s)
                for hint in state.partyHints where hint.slot < Self.partySlots.count {
                    drawHint(hint, at: Self.partySlots[hint.slot], ctx: ctx, s: s)
                }
                return
            }
            if let box = state.enemyBox, !state.weaknesses.isEmpty {
                drawWeaknesses(state.weaknesses, at: CGPoint(x: box.x + 2, y: box.y - 12), icon: 10, ctx: ctx, s: s)
            }
            for tag in state.moveTags where tag.slot < Self.moveSlots.count {
                drawTag(tag.multiplier, at: Self.moveSlots[tag.slot], ctx: ctx, s: s)
            }
        }
        .allowsHitTesting(false)
    }

    /// Each type it is weak to: the type's icon, then its multiplier. Tightens when there are many.
    private func drawWeaknesses(_ list: [BattleOverlayState.Weakness], at origin: CGPoint, icon size: CGFloat,
                                ctx: GraphicsContext, s: CGFloat) {
        let labels = list.map { "x" + MicroFont.number($0.multiplier) }
        let layouts: [(icon: CGFloat, gap: CGFloat)] = [(size, 4), (size, 2), (8, 2), (8, 1)]
        let start = origin.x
        let layout = layouts.first { l in
            start + zip(list, labels).reduce(CGFloat(0)) { $0 + l.icon + 1 + MicroFont.width($1.1) + l.gap } <= Self.weaknessRowEnd
        } ?? layouts[layouts.count - 1]
        var x = start
        let top = origin.y
        for (w, label) in zip(list, labels) {
            if let icon = overlay.typeIcons[w.type] {
                let inset = (10 - layout.icon) / 2
                ctx.draw(Image(uiImage: icon).interpolation(.none),
                         in: CGRect(x: x * s, y: (top + inset) * s, width: layout.icon * s, height: layout.icon * s))
            }
            x += layout.icon + 1
            MicroFont.draw(label, x: x + 1, y: top + 4, color: Color(red: 16 / 255, green: 16 / 255, blue: 32 / 255), ctx: ctx, s: s)
            MicroFont.draw(label, x: x, y: top + 3, color: Color(white: 0.97), ctx: ctx, s: s)
            x += MicroFont.width(label) + layout.gap
        }
    }

    /// A switch-screen slot: the enemy's type that hits this member hardest, and how hard (red worse, green better).
    private func drawHint(_ hint: BattleOverlayState.PartyHint, at p: CGPoint, ctx: GraphicsContext, s: CGFloat) {
        if let icon = overlay.typeIcons[hint.type] {
            ctx.draw(Image(uiImage: icon).interpolation(.none), in: CGRect(x: p.x * s, y: (p.y - 1) * s, width: 8 * s, height: 8 * s))
        }
        let label = "x" + MicroFont.number(hint.multiplier)
        let color = hint.multiplier > 1 ? Color(red: 1, green: 150 / 255, blue: 132 / 255)
                                        : Color(red: 150 / 255, green: 1, blue: 170 / 255)
        MicroFont.draw(label, x: p.x + 10, y: p.y + 2, color: Color(red: 16 / 255, green: 16 / 255, blue: 32 / 255), ctx: ctx, s: s)
        MicroFont.draw(label, x: p.x + 9, y: p.y + 1, color: color, ctx: ctx, s: s)
    }

    /// Under a move's name: a short line in the effectiveness colour, then the multiplier.
    private func drawTag(_ m: Double, at p: CGPoint, ctx: GraphicsContext, s: CGFloat) {
        let color = Self.color(m)
        ctx.fill(Path(CGRect(x: p.x * s, y: (p.y + 1) * s, width: 10 * s, height: 3 * s)), with: .color(color))
        MicroFont.draw("x" + MicroFont.number(m), x: p.x + 12, y: p.y, color: color, ctx: ctx, s: s)
    }

    /// Readable on the white move menu: green super effective, grey neutral, orange and red resisted, pale grey none.
    private static func color(_ m: Double) -> Color {
        func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r / 255, green: g / 255, blue: b / 255) }
        switch m {
        case 4...: return rgb(0, 150, 64)
        case 2..<4: return rgb(40, 168, 80)
        case 1: return rgb(96, 96, 104)
        case 0.5..<1: return rgb(232, 112, 32)
        case 0: return rgb(150, 150, 160)
        default: return rgb(208, 48, 40)
        }
    }
}

/// A 3x5 pixel font for the multipliers: small enough for the gaps the game leaves, crisp at any scale.
enum MicroFont {
    private static let glyphs: [Character: [String]] = [
        "0": ["111", "101", "101", "101", "111"], "1": ["010", "110", "010", "010", "111"],
        "2": ["111", "001", "111", "100", "111"], "3": ["111", "001", "111", "001", "111"],
        "4": ["101", "101", "111", "001", "001"], "5": ["111", "100", "111", "001", "111"],
        "6": ["111", "100", "111", "101", "111"], "7": ["111", "001", "010", "010", "010"],
        "8": ["111", "101", "111", "101", "111"], "9": ["111", "101", "111", "001", "111"],
        ".": ["0", "0", "0", "0", "1"], "x": ["000", "101", "010", "101", "000"],
    ]

    /// "4", "2", "1", "0.5", "0.25", "0".
    static func number(_ m: Double) -> String {
        if m == m.rounded() { return String(Int(m)) }
        var text = String(format: "%.3f", m)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    static func width(_ text: String) -> CGFloat {
        CGFloat(text.reduce(0) { $0 + (glyphs[$1]?.first?.count ?? 3) + 1 } - 1)
    }

    static func draw(_ text: String, x: CGFloat, y: CGFloat, color: Color, ctx: GraphicsContext, s: CGFloat) {
        var path = Path()
        var cx = x
        for ch in text {
            guard let rows = glyphs[ch] else { cx += 4; continue }
            for (j, row) in rows.enumerated() {
                for (i, bit) in row.enumerated() where bit == "1" {
                    path.addRect(CGRect(x: (cx + CGFloat(i)) * s, y: (y + CGFloat(j)) * s, width: s, height: s))
                }
            }
            cx += CGFloat(rows[0].count + 1)
        }
        ctx.fill(path, with: .color(color))
    }
}
