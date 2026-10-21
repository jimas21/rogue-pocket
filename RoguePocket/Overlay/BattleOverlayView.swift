import SwiftUI

/// Draws the battle overlay over the game picture. Everything is placed in GBA pixels and scaled with the picture,
/// so it lines up in portrait and landscape alike, and it sits only on empty background or blank menu space.
struct BattleOverlayView: View {
    @ObservedObject var overlay: BattleOverlay

    /// Where each move's name starts in the move menu, and the free row under it.
    private static let moveSlots = [CGPoint(x: 16, y: 134), CGPoint(x: 88, y: 134),
                                    CGPoint(x: 16, y: 151), CGPoint(x: 88, y: 151)]
    /// The switch screen: the first member's big card (its free spot is just above the card), then the free gap in
    /// the second row of each of the five slots on the right.
    private static let partySlots = [CGPoint(x: 60, y: 17)] + (0..<5).map { CGPoint(x: 165, y: 26 + 24 * CGFloat($0)) }
    private static let shadow = Color(red: 16 / 255, green: 16 / 255, blue: 32 / 255)

    var body: some View {
        Canvas { ctx, size in
            guard let state = overlay.state else { return }
            let s = size.width / 240
            if state.partyMenu {
                drawSwitchScreen(state, ctx: ctx, s: s)
                return
            }
            if state.doubles {
                drawDoublesWeaknesses(state.foes, ctx: ctx, s: s)
            } else if let foe = state.foes.first, let box = foe.box {
                // Singles: its own types small, inside its HP box in the dark band between the Poke Ball mark and
                // "HP"; what it is weak to on the empty background above the box, ending before its sprite (x 144).
                drawTypes(foe.types, x: box.x + 15, y: box.y + 17, icon: 6, gap: 0, divider: false, ctx: ctx, s: s)
                drawRow(foe.weaknesses, x: box.x + 2, y: box.y - 12, icon: 10, end: 143, ctx: ctx, s: s)
            }
            if let box = state.playerBox, !state.playerTypes.isEmpty {
                // Your types in your HP box's empty corner, right of where a status (PSN, BRN...) appears.
                drawTypes(state.playerTypes, x: box.x + 42, y: box.y + 24, icon: 8, divider: false, ctx: ctx, s: s)
            }
            for tag in state.moveTags where tag.slot < Self.moveSlots.count {
                drawTag(tag.multipliers, at: Self.moveSlots[tag.slot], ctx: ctx, s: s)
            }
        }
        .allowsHitTesting(false)
    }

    /// Doubles: the two HP boxes stack at the top left and the foes stand to the right (the nearer one's sprite
    /// starts at x 120). Each foe's weaknesses fill the background between, beside its own box, two to a row.
    private func drawDoublesWeaknesses(_ foes: [BattleOverlayState.Foe], ctx: GraphicsContext, s: CGFloat) {
        let placed = foes.compactMap { f in f.box.map { (foe: f, box: $0) } }.sorted { $0.box.y < $1.box.y }
        guard let right = placed.map({ $0.box.x + 64 }).max() else { return }
        let x0 = right + 2
        var top: CGFloat = 0
        for (i, p) in placed.enumerated() {
            let y0 = max(p.box.y + 1, top)
            let yEnd = i + 1 < placed.count ? p.box.y + 32 : 56   // the lower box's rows stop above your Pokemon
            var x = drawTypes(p.foe.types, x: x0, y: y0, icon: 8, ctx: ctx, s: s), y = y0
            for w in p.foe.weaknesses {
                let width = 8 + 1 + MicroFont.width(label(w.multiplier))
                if x + width > 119 { x = x0; y += 9 }
                if y + 8 > yEnd { break }
                drawWeakness(w, x: x, y: y, icon: 8, ctx: ctx, s: s)
                x += width + 2
            }
            top = p.box.y + 33
        }
    }

    /// The switch screen: the foes' weaknesses on the empty background top left (in doubles a small picture says
    /// whose row it is), and each member's hint in its slot.
    private func drawSwitchScreen(_ state: BattleOverlayState, ctx: GraphicsContext, s: CGFloat) {
        for (i, foe) in state.foes.enumerated() {
            let y = 3 + 10 * CGFloat(i)
            var x: CGFloat = 4
            if state.doubles {
                if let sprite = overlay.foeSprite(foe.species) {
                    ctx.draw(Image(uiImage: sprite).interpolation(.none), in: CGRect(x: x * s, y: (y - 1) * s, width: 10 * s, height: 10 * s))
                }
                x += 12
            }
            x = drawTypes(foe.types, x: x, y: y + 1, icon: 8, ctx: ctx, s: s)
            drawRow(foe.weaknesses, x: x, y: y, icon: 8, end: 94, ctx: ctx, s: s)
        }
        for hint in state.partyHints where hint.slot < Self.partySlots.count {
            drawHint(hint, at: Self.partySlots[hint.slot], ctx: ctx, s: s)
        }
    }

    private func label(_ m: Double) -> String { "x" + MicroFont.number(m) }

    /// A Pokemon's own types (a repeated type and the empty third type drawn once / not at all), then optionally a thin
    /// divider before what follows. Returns where the next thing starts.
    @discardableResult
    private func drawTypes(_ types: [Int], x start: CGFloat, y: CGFloat, icon size: CGFloat, gap: CGFloat = 1,
                           divider: Bool = true, ctx: GraphicsContext, s: CGFloat) -> CGFloat {
        var shown: [Int] = []
        for t in types where t != 9 && !shown.contains(t) { shown.append(t) }
        var x = start
        for t in shown {
            if let icon = overlay.typeIcons[t] {
                ctx.draw(Image(uiImage: icon).interpolation(.none), in: CGRect(x: x * s, y: y * s, width: size * s, height: size * s))
            }
            x += size + gap
        }
        guard divider, !shown.isEmpty else { return x }
        ctx.fill(Path(CGRect(x: (x + 1) * s, y: (y + 1) * s, width: s, height: (size - 2) * s)),
                 with: .color(Color(white: 0.97).opacity(0.7)))
        return x + 4
    }

    /// A row of weaknesses: each type's icon, then its multiplier. Tightens when there are many.
    private func drawRow(_ list: [BattleOverlayState.Weakness], x start: CGFloat, y top: CGFloat, icon size: CGFloat,
                         end: CGFloat, ctx: GraphicsContext, s: CGFloat) {
        let layouts: [(icon: CGFloat, gap: CGFloat)] = [(size, 2), (size, 1), (8, 1), (8, 0)]   // close together
        let layout = layouts.first { l in
            start + list.reduce(CGFloat(0)) { $0 + l.icon + 1 + MicroFont.width(label($1.multiplier)) + l.gap } <= end
        } ?? layouts[layouts.count - 1]
        var x = start
        for w in list {
            drawWeakness(w, x: x, y: top + (10 - layout.icon) / 2, icon: layout.icon, ctx: ctx, s: s)
            x += layout.icon + 1 + MicroFont.width(label(w.multiplier)) + layout.gap
        }
    }

    /// One weakness: the type's icon, then its multiplier beside it (vertically centred on the icon).
    private func drawWeakness(_ w: BattleOverlayState.Weakness, x: CGFloat, y: CGFloat, icon size: CGFloat,
                              ctx: GraphicsContext, s: CGFloat) {
        if let icon = overlay.typeIcons[w.type] {
            ctx.draw(Image(uiImage: icon).interpolation(.none), in: CGRect(x: x * s, y: y * s, width: size * s, height: size * s))
        }
        let ly = y + ((size - 5) / 2).rounded()
        // A full dark outline, not just a drop shadow: the labels sit on whatever the battle background is (pale sky
        // on some routes), and must read on all of them.
        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (1, 1)] as [(CGFloat, CGFloat)] {
            MicroFont.draw(label(w.multiplier), x: x + size + 1 + dx, y: ly + dy, color: Self.shadow, ctx: ctx, s: s)
        }
        MicroFont.draw(label(w.multiplier), x: x + size + 1, y: ly, color: Color(white: 0.97), ctx: ctx, s: s)
    }

    /// A switch-screen slot: the foes' type that hits this member hardest, and how hard (red worse, green better).
    private func drawHint(_ hint: BattleOverlayState.PartyHint, at p: CGPoint, ctx: GraphicsContext, s: CGFloat) {
        if let icon = overlay.typeIcons[hint.type] {
            ctx.draw(Image(uiImage: icon).interpolation(.none), in: CGRect(x: p.x * s, y: (p.y - 1) * s, width: 8 * s, height: 8 * s))
        }
        let color = hint.multiplier > 1 ? Color(red: 1, green: 150 / 255, blue: 132 / 255)
                                        : Color(red: 150 / 255, green: 1, blue: 170 / 255)
        MicroFont.draw(label(hint.multiplier), x: p.x + 10, y: p.y + 2, color: Self.shadow, ctx: ctx, s: s)
        MicroFont.draw(label(hint.multiplier), x: p.x + 9, y: p.y + 1, color: color, ctx: ctx, s: s)
    }

    /// Under a move's name: a short line in the effectiveness colour, then the multiplier. In doubles, one multiplier
    /// per foe, upper HP box first ("x2/x0.5"); the line takes the better one's colour.
    private func drawTag(_ ms: [Double], at p: CGPoint, ctx: GraphicsContext, s: CGFloat) {
        guard let best = ms.max() else { return }
        ctx.fill(Path(CGRect(x: p.x * s, y: (p.y + 1) * s, width: 10 * s, height: 3 * s)), with: .color(Self.color(best)))
        var x = p.x + 12
        for (i, m) in ms.enumerated() {
            if i > 0 {
                MicroFont.draw("/", x: x, y: p.y, color: Self.color(1), ctx: ctx, s: s)
                x += MicroFont.width("/") + 1
            }
            MicroFont.draw(label(m), x: x, y: p.y, color: Self.color(m), ctx: ctx, s: s)
            x += MicroFont.width(label(m)) + 1
        }
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
        "/": ["001", "001", "010", "100", "100"],
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
