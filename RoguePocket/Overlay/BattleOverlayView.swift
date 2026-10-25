import SwiftUI

/// Draws the battle overlay over the game picture. Everything is placed in GBA pixels and scaled with the picture,
/// so it lines up in portrait and landscape alike, and it sits only on empty background or blank menu space.
struct BattleOverlayView: View {
    @ObservedObject var overlay: BattleOverlay

    /// Where each move's name starts in the move menu and the blank 4 px band under it (the letters' tails end the
    /// row above the band).
    private static let moveSlots = [CGPoint(x: 16, y: 136), CGPoint(x: 88, y: 136),
                                    CGPoint(x: 16, y: 152), CGPoint(x: 88, y: 152)]
    /// The mark under a move's name: a two-bar pip (3 x 2 px bars) says which foe a number is for when two are up.
    private static let markPipWidth: CGFloat = 3
    private static let markPipBar: CGFloat = 2
    private static let markPipAdvance: CGFloat = 4
    private static let markGap: CGFloat = 4
    private static let markPale = Color(red: 196 / 255, green: 196 / 255, blue: 204 / 255)
    /// Types inside an HP box, in the blank band at the left end of the HP-bar row under the name (a foe's box starts
    /// its icons at foeTypesX, yours at ownTypesX). Three types are drawn smaller (6 px, 1 px apart), start 2 px further
    /// left and 1 px lower, so all three end before the "HP" label.
    private static let foeTypesX: CGFloat = 8
    private static let ownTypesX: CGFloat = 16
    private static let typesY: CGFloat = 15
    private static let typesIcon: CGFloat = 8
    private static let typesGap: CGFloat = 1
    private static let threeTypesShift: CGFloat = 2
    private static let threeTypesGap: CGFloat = 1
    private static let threeTypesIcon: CGFloat = 6
    private static let threeTypesDrop: CGFloat = 1
    /// The switch screen: the first member's big card (its free spot is just above the card), then the free gap in
    /// the second row of each of the five slots on the right.
    private static let partySlots = [CGPoint(x: 60, y: 17)] + (0..<5).map { CGPoint(x: 165, y: 26 + 24 * CGFloat($0)) }
    private static let shadow = Color(red: 16 / 255, green: 16 / 255, blue: 32 / 255)

    var body: some View {
        Canvas { ctx, size in
            // A box slides in from far outside the picture, and nothing may paint on the controls beside it.
            ctx.clip(to: Path(CGRect(origin: .zero, size: size)))
            guard let state = overlay.state else { return }
            let s = size.width / 240
            if state.partyMenu {
                drawSwitchScreen(state, ctx: ctx, s: s)
                return
            }
            // A double battle draws only the types inside the four HP boxes and the move marks: both foes' weakness
            // lists are in the strip under the picture and in the band above it. While the game fades the boxes or the
            // screen nothing sits on the picture: the singles foe's types stay off with the others (typesOff), and its
            // weaknesses and your types are skipped here.
            if !state.doubles, let foe = state.foes.first, let box = foe.box {
                // Singles: its own types inside its HP box, left of "HP", placed like every other foe box (three types
                // are drawn smaller so they end before the label); what it is weak to on the empty background above
                // the box, ending before its sprite (x 144).
                drawBoxTypes(foe.types, battler: foe.battler, box: box, x: Self.foeTypesX, state: state, ctx: ctx, s: s)
                if !state.fading {
                    drawRow(foe.weaknesses, x: box.x + 2, y: box.y - 11, icon: 8, end: 143, ctx: ctx, s: s)
                }
            }
            if !state.fading, let box = state.playerBox, !state.playerTypes.isEmpty {
                // Your types in your HP box's empty corner, right of where a status (PSN, BRN...) appears.
                drawTypes(state.playerTypes, x: box.x + 42, y: box.y + 24, icon: 8, divider: false, ctx: ctx, s: s)
            }
            if state.doubles {
                for foe in state.foes {
                    drawBoxTypes(foe.types, battler: foe.battler, box: foe.box, x: Self.foeTypesX, state: state, ctx: ctx, s: s)
                }
                for mon in state.own {
                    drawBoxTypes(mon.types, battler: mon.battler, box: mon.box, x: Self.ownTypesX, state: state, ctx: ctx, s: s)
                }
            }
            for tag in state.moveTags where tag.slot < Self.moveSlots.count {
                drawTag(tag.multipliers, at: Self.moveSlots[tag.slot], ctx: ctx, s: s)
            }
        }
        .allowsHitTesting(false)
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

    /// A Pokemon's types inside its HP box, unless the box is to stay bare right now. Three types are drawn smaller,
    /// 1 px apart, 2 px further left and 1 px lower, so they still end before the "HP" label.
    private func drawBoxTypes(_ types: [Int], battler: Int, box: CGPoint?, x offset: CGFloat, state: BattleOverlayState,
                              ctx: GraphicsContext, s: CGFloat) {
        guard let box, !state.typesOff.contains(battler) else { return }
        var shown: [Int] = []
        for t in types where t != 9 && !shown.contains(t) { shown.append(t) }
        if shown.count >= 3 {
            drawTypes(types, x: box.x + offset - Self.threeTypesShift, y: box.y + Self.typesY + Self.threeTypesDrop,
                      icon: Self.threeTypesIcon, gap: Self.threeTypesGap, divider: false, ctx: ctx, s: s)
        } else {
            drawTypes(types, x: box.x + offset, y: box.y + Self.typesY, icon: Self.typesIcon, gap: Self.typesGap,
                      divider: false, ctx: ctx, s: s)
        }
    }

    /// A row of weaknesses: each type's icon, then its multiplier. Tightens when there are many.
    private func drawRow(_ list: [BattleOverlayState.Weakness], x start: CGFloat, y top: CGFloat, icon size: CGFloat,
                         end: CGFloat, ctx: GraphicsContext, s: CGFloat) {
        let layouts: [(icon: CGFloat, gap: CGFloat)] = [(size, 3), (size, 2), (size, 1), (size, 0)]   // close together
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

    /// Under a move's name: its multiplier against each foe on the field, upper HP box first, in the effectiveness
    /// colour. With two foes a small two-bar mark before each number says which foe it is for: the top bar for the
    /// upper foe, the bottom bar for the lower, the other bar pale.
    private func drawTag(_ ms: [Double], at p: CGPoint, ctx: GraphicsContext, s: CGFloat) {
        var x = p.x
        for (i, m) in ms.enumerated() {
            if ms.count == 2 {
                let own = Self.color(m)
                let top = i == 0 ? own : Self.markPale
                let bottom = i == 0 ? Self.markPale : own
                ctx.fill(Path(CGRect(x: x * s, y: p.y * s, width: Self.markPipWidth * s, height: Self.markPipBar * s)),
                         with: .color(top))
                ctx.fill(Path(CGRect(x: x * s, y: (p.y + Self.markPipBar) * s, width: Self.markPipWidth * s,
                                     height: Self.markPipBar * s)), with: .color(bottom))
                x += Self.markPipAdvance
            }
            MicroFont.drawShort(label(m), x: x, y: p.y, color: Self.color(m), ctx: ctx, s: s)
            x += MicroFont.width(label(m)) + Self.markGap
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

    /// The characters of a move mark, cut to four rows for the 4 px band under a move name (a five-row glyph does not
    /// fit there).
    private static let shortGlyphs: [Character: [String]] = [
        "0": ["111", "101", "101", "111"], "1": ["010", "110", "010", "111"], "2": ["111", "011", "110", "111"],
        "4": ["101", "111", "001", "001"], "5": ["111", "110", "011", "111"], ".": ["0", "0", "0", "1"],
        "x": ["000", "101", "010", "101"],
        "8": ["111", "101", "111", "111"],
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

    /// `draw` with the four-row cut, for the 4 px band under a move name. Each glyph is as wide as the five-row one,
    /// so `width` serves both.
    static func drawShort(_ text: String, x: CGFloat, y: CGFloat, color: Color, ctx: GraphicsContext, s: CGFloat) {
        var path = Path()
        var cx = x
        for ch in text {
            guard let rows = shortGlyphs[ch] else { cx += 4; continue }
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
