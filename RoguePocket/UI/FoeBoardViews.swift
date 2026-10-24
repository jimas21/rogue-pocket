import SwiftUI
import UIKit

// Both foes' weakness lists in a double battle: a strip under the picture in portrait and a panel above the picture in
// landscape. Every position comes from FoeBoardMetrics and the width it is given, never from a text width or from how
// many weaknesses a foe has, so nothing moves as the content changes.

/// Every number the strip and the landscape panel are laid out with, in points. Strip values are measured inside the
/// strip's side padding from its top edge. One value per line, so a tool can read them.
enum FoeBoardMetrics {
    // Portrait strip
    static let stripHeaderTop: CGFloat = 8
    static let stripPipWidth: CGFloat = 5
    static let stripPipBar: CGFloat = 4
    static let stripPipTop: CGFloat = 2
    static let stripPipGap: CGFloat = 1
    static let stripNameX: CGFloat = 8
    static let stripNameSize: CGFloat = 13
    static let stripIcon: CGFloat = 13
    static let stripFirstRowTop: CGFloat = 23
    static let stripRowPitch: CGFloat = 15
    static let stripLabelGap: CGFloat = 2
    static let stripLabelSize: CGFloat = 12
    static let stripColumnGap: CGFloat = 8
    static let stripPerRow: CGFloat = 4
    static let stripEntrySlack: CGFloat = 6
    static let stripDividerTop: CGFloat = 10
    static let stripDividerBottom: CGFloat = 54

    // Landscape panel above the picture
    static let bandMinHeight: CGFloat = 35
    static let bandPanelHeight: CGFloat = 32
    static let bandCorner: CGFloat = 8
    static let bandPadV: CGFloat = 2
    static let bandIcon: CGFloat = 13
    static let bandRowPitch: CGFloat = 15
    static let bandSide: CGFloat = 12
    static let bandPipWidth: CGFloat = 7
    static let bandPipBar: CGFloat = 4.5
    static let bandPipGap: CGFloat = 1.5
    static let bandPipToName: CGFloat = 6
    static let bandNameToList: CGFloat = 12
    static let bandLabelGap: CGFloat = 2
    static let bandEntryGap: CGFloat = 7
    static let bandTextSize: CGFloat = 12

    // Both
    static let dimOpacity: CGFloat = 0.45
}

private enum FoeBoardColor {
    static let bright = Color(red: 240 / 255, green: 240 / 255, blue: 236 / 255)
    static let dim = Color(red: 110 / 255, green: 122 / 255, blue: 116 / 255)
    static let pale = Color(red: 92 / 255, green: 108 / 255, blue: 100 / 255)
    static let paleDim = Color(red: 60 / 255, green: 72 / 255, blue: 66 / 255)
    static let divider = Color(red: 60 / 255, green: 78 / 255, blue: 70 / 255)
    static let panel = Color(red: 22 / 255, green: 33 / 255, blue: 29 / 255)
}

private extension FoeBoard {
    /// A foe is bright unless another foe is the one being aimed at.
    func isBright(_ foe: BattleOverlayState.Foe) -> Bool {
        guard let aimed, foes.contains(where: { $0.battler == aimed }) else { return true }
        return foe.battler == aimed
    }
}

private extension View {
    /// Puts the middle of the text's capital letters on its centre line, so beside an icon the capitals and the icon
    /// share one centre (the plain centre would sit the letters low by half the descent).
    func capCentred(size: CGFloat) -> some View {
        let cap = UIFont.systemFont(ofSize: size, weight: .bold).capHeight
        return alignmentGuide(VerticalAlignment.center) { d in d[.firstTextBaseline] - cap / 2 }
    }
}

/// Two stacked bars like the two HP boxes: the foe's own bar is bright and the other pale. With one foe on the field
/// both bars are bright.
private struct FoePip: View {
    let index: Int
    let count: Int
    let bright: Bool
    let width: CGFloat
    let bar: CGFloat
    let gap: CGFloat

    var body: some View {
        VStack(spacing: gap) {
            Rectangle().fill(color(own: count < 2 || index == 0)).frame(width: width, height: bar)
            Rectangle().fill(color(own: count < 2 || index == 1)).frame(width: width, height: bar)
        }
    }

    private func color(own: Bool) -> Color {
        if own { return bright ? FoeBoardColor.bright : FoeBoardColor.dim }
        return bright ? FoeBoardColor.pale : FoeBoardColor.paleDim
    }
}

/// One weakness: the type's icon, then its multiplier. The icon's square is kept when the picture is not loaded yet,
/// so nothing shifts when it arrives.
private struct WeaknessEntry: View {
    let weakness: BattleOverlayState.Weakness
    let image: UIImage?
    let dimmed: Bool
    let icon: CGFloat
    let labelGap: CGFloat
    let labelSize: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: labelGap) {
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: icon, height: icon)
                    .opacity(dimmed ? Double(FoeBoardMetrics.dimOpacity) : 1)
            } else {
                Color.clear.frame(width: icon, height: icon)
            }
            Text("x" + MicroFont.number(weakness.multiplier))
                .font(.system(size: labelSize, weight: .bold))
                .foregroundStyle(dimmed ? FoeBoardColor.dim : FoeBoardColor.bright)
                .fixedSize()
                .capCentred(size: labelSize)
        }
    }
}

/// The portrait strip's content in a double battle: one column per foe, upper foe first, each with its position pip,
/// its name and every weakness as icon + multiplier, four to a row. The view fills the space it is given and clips to
/// it.
struct FoeBoardStrip: View {
    let board: FoeBoard
    @ObservedObject var overlay: BattleOverlay
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private typealias M = FoeBoardMetrics

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let columnWidth = (width - M.stripColumnGap) / 2
            let step = (columnWidth - M.stripEntrySlack) / M.stripPerRow
            let foes = Array(board.foes.prefix(2))
            let animation: Animation? = reduceMotion ? nil : .easeOut(duration: 0.1)
            ZStack(alignment: .topLeading) {
                ForEach(Array(foes.enumerated()), id: \.offset) { index, foe in
                    FoeStripColumn(foe: foe, index: index, count: foes.count, bright: board.isBright(foe),
                                   columnWidth: columnWidth, step: step, overlay: overlay)
                        .offset(x: CGFloat(index) * (columnWidth + M.stripColumnGap))
                }
                if foes.count == 2 {
                    Rectangle()
                        .fill(FoeBoardColor.divider)
                        .frame(width: 1, height: M.stripDividerBottom - M.stripDividerTop)
                        .offset(x: width / 2 - 0.5, y: M.stripDividerTop)
                }
            }
            .frame(width: width, height: geo.size.height, alignment: .topLeading)
            .animation(animation, value: board.aimed)
        }
        .clipped()
    }
}

private struct FoeStripColumn: View {
    let foe: BattleOverlayState.Foe
    let index: Int
    let count: Int
    let bright: Bool
    let columnWidth: CGFloat
    let step: CGFloat
    @ObservedObject var overlay: BattleOverlay
    private typealias M = FoeBoardMetrics

    var body: some View {
        let pipHeight = 2 * M.stripPipBar + M.stripPipGap
        let headerY = M.stripHeaderTop + M.stripPipTop
        let perRow = Int(M.stripPerRow)
        ZStack(alignment: .topLeading) {
            FoePip(index: index, count: count, bright: bright, width: M.stripPipWidth, bar: M.stripPipBar,
                   gap: M.stripPipGap)
                .offset(y: headerY)
            Text(overlay.data?.speciesName(foe.species) ?? "")
                .font(.system(size: M.stripNameSize, weight: .bold))
                .foregroundStyle(bright ? FoeBoardColor.bright : FoeBoardColor.dim)
                .lineLimit(1)
                .truncationMode(.tail)
                .capCentred(size: M.stripNameSize)
                .frame(width: columnWidth - M.stripNameX, height: pipHeight, alignment: .leading)
                .offset(x: M.stripNameX, y: headerY)
            ForEach(Array(foe.weaknesses.enumerated()), id: \.offset) { k, weakness in
                WeaknessEntry(weakness: weakness, image: overlay.typeIcons[weakness.type], dimmed: !bright,
                              icon: M.stripIcon, labelGap: M.stripLabelGap, labelSize: M.stripLabelSize)
                    .frame(width: step, height: M.stripIcon, alignment: .leading)
                    .offset(x: CGFloat(k % perRow) * step,
                            y: M.stripFirstRowTop + CGFloat(k / perRow) * M.stripRowPitch)
            }
        }
    }
}

/// The landscape panel in a double battle: one row per foe, upper foe first, each with its position pip, its name and
/// every weakness as icon + multiplier on a single line. It is as wide as the space it is given and always
/// bandPanelHeight tall; display only.
struct FoeBoardBand: View {
    let board: FoeBoard
    @ObservedObject var overlay: BattleOverlay
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private typealias M = FoeBoardMetrics

    var body: some View {
        let foes = Array(board.foes.prefix(2))
        let animation: Animation? = reduceMotion ? nil : .easeOut(duration: 0.1)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: M.bandCorner).fill(FoeBoardColor.panel)
            ForEach(Array(foes.enumerated()), id: \.offset) { index, foe in
                FoeBandRow(foe: foe, index: index, count: foes.count, bright: board.isBright(foe),
                           name: overlay.data?.speciesName(foe.species) ?? "", icons: overlay.typeIcons)
                    .offset(y: M.bandPadV + CGFloat(index) * M.bandRowPitch)
            }
        }
        .frame(maxWidth: .infinity, minHeight: M.bandPanelHeight, maxHeight: M.bandPanelHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: M.bandCorner))
        .animation(animation, value: board.aimed)
        .allowsHitTesting(false)
    }
}

private struct FoeBandRow: View {
    let foe: BattleOverlayState.Foe
    let index: Int
    let count: Int
    let bright: Bool
    let name: String
    let icons: [Int: UIImage]
    private typealias M = FoeBoardMetrics

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Color.clear.frame(width: M.bandSide, height: 1)
            FoePip(index: index, count: count, bright: bright, width: M.bandPipWidth, bar: M.bandPipBar,
                   gap: M.bandPipGap)
            Color.clear.frame(width: M.bandPipToName, height: 1)
            Text(name)
                .font(.system(size: M.bandTextSize, weight: .bold))
                .foregroundStyle(bright ? FoeBoardColor.bright : FoeBoardColor.dim)
                .fixedSize()
                .capCentred(size: M.bandTextSize)
            Color.clear.frame(width: M.bandNameToList, height: 1)
            HStack(alignment: .center, spacing: M.bandEntryGap) {
                ForEach(Array(foe.weaknesses.enumerated()), id: \.offset) { _, weakness in
                    WeaknessEntry(weakness: weakness, image: icons[weakness.type], dimmed: !bright,
                                  icon: M.bandIcon, labelGap: M.bandLabelGap, labelSize: M.bandTextSize)
                }
            }
        }
        .fixedSize()
        .frame(height: M.bandIcon, alignment: .leading)
    }
}
