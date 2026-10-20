import SwiftUI
import UIKit

// On-screen controls. One UIKit view per pad tracks every finger itself (touchesBegan/Moved/Ended), the way
// emulator front ends do it: true multi-touch, a thumb can slide across the D-pad or from B onto A, and nothing
// depends on SwiftUI gesture arbitration between sibling views. (Build 6 used one SwiftUI gesture per button in an
// HStack 408 pt wide on a 393 pt phone: the buttons overlapped and most presses never reached the game.)

/// One control, placed in its pad: `center` is a fraction of the pad's size, `size` is in points.
struct PadElement {
    enum Kind {
        case button(GBAKeys, String, round: Bool)
        case dpad
    }

    let kind: Kind
    let center: CGPoint
    let size: CGSize

    static func button(_ keys: GBAKeys, _ label: String, x: CGFloat, y: CGFloat, w: CGFloat = 64, h: CGFloat = 64,
                       round: Bool = true) -> PadElement {
        PadElement(kind: .button(keys, label, round: round), center: CGPoint(x: x, y: y), size: CGSize(width: w, height: h))
    }

    static func dpad(x: CGFloat, y: CGFloat, side: CGFloat = 150) -> PadElement {
        PadElement(kind: .dpad, center: CGPoint(x: x, y: y), size: CGSize(width: side, height: side))
    }
}

enum PadLayout {
    /// Portrait: one pad under the game picture.
    static let portrait: [PadElement] = [
        .button(.l, "L", x: 0.14, y: 0.09, w: 92, h: 38, round: false),
        .button(.r, "R", x: 0.86, y: 0.09, w: 92, h: 38, round: false),
        .dpad(x: 0.25, y: 0.48),
        .button(.a, "A", x: 0.86, y: 0.40),
        .button(.b, "B", x: 0.68, y: 0.56),
        .button(.select, "Select", x: 0.40, y: 0.87, w: 74, h: 30),
        .button(.start, "Start", x: 0.60, y: 0.87, w: 74, h: 30),
    ]

    /// Landscape: a pad on each side of the picture.
    static let landscapeLeft: [PadElement] = [
        .button(.l, "L", x: 0.5, y: 0.12, w: 92, h: 38, round: false),
        .dpad(x: 0.5, y: 0.53, side: 140),
        .button(.select, "Select", x: 0.5, y: 0.90, w: 74, h: 30),
    ]

    static let landscapeRight: [PadElement] = [
        .button(.r, "R", x: 0.5, y: 0.12, w: 92, h: 38, round: false),
        .button(.a, "A", x: 0.72, y: 0.43, w: 60, h: 60),
        .button(.b, "B", x: 0.30, y: 0.61, w: 60, h: 60),
        .button(.start, "Start", x: 0.5, y: 0.90, w: 74, h: 30),
    ]
}

/// SwiftUI face of ControllerView. `layoutID` names the pad, so two pads (landscape) can be held at once.
struct ControllerPad: UIViewRepresentable {
    let elements: [PadElement]
    let layoutID: String
    let emulator: Emulator

    func makeUIView(context: Context) -> ControllerView {
        let view = ControllerView()
        view.configure(elements, id: layoutID)
        let emu = emulator
        let source = layoutID
        view.onKeys = { keys in emu.setTouchKeys(keys, from: source) }
        return view
    }

    func updateUIView(_ uiView: ControllerView, context: Context) {
        uiView.configure(elements, id: layoutID) // no-op unless the layout changed
    }

    static func dismantleUIView(_ uiView: ControllerView, coordinator: ()) {
        uiView.releaseAll()
    }
}

final class ControllerView: UIView {
    var onKeys: ((GBAKeys) -> Void)?

    private var elements: [PadElement] = []
    private var layoutID = ""
    private var views: [UIView] = []
    private var dpadArms: [(GBAKeys, UIView)] = []
    private var touchKeys: [ObjectIdentifier: GBAKeys] = [:]
    private var pressed: GBAKeys = []
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    private static let idle = UIColor.white.withAlphaComponent(0.22)
    private static let lit = UIColor.systemGreen.withAlphaComponent(0.85)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func configure(_ elements: [PadElement], id: String) {
        guard id != layoutID else { return }
        releaseAll()
        layoutID = id
        self.elements = elements
        views.forEach { $0.removeFromSuperview() }
        views = []
        dpadArms = []
        for element in elements {
            let v: UIView
            switch element.kind {
            case .button(_, let label, let round):
                let b = UILabel()
                b.text = label
                b.textAlignment = .center
                b.textColor = .white
                b.font = .systemFont(ofSize: label.count > 1 ? 15 : 20, weight: .bold)
                b.backgroundColor = Self.idle
                b.layer.cornerRadius = round ? element.size.height / 2 : 12
                b.layer.masksToBounds = true
                v = b
            case .dpad:
                let pad = UIView()
                for key in [GBAKeys.up, .down, .left, .right] {
                    let arm = UIView()
                    arm.backgroundColor = Self.idle
                    arm.layer.cornerRadius = 10
                    pad.addSubview(arm)
                    dpadArms.append((key, arm))
                }
                v = pad
            }
            v.isUserInteractionEnabled = false // this view does all the touch handling
            addSubview(v)
            views.append(v)
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (element, v) in zip(elements, views) {
            v.frame = frame(of: element)
            guard case .dpad = element.kind else { continue }
            let s = v.bounds.width
            let arm = s / 3
            let len = s / 2.6
            for (key, armView) in dpadArms {
                switch key {
                case .up: armView.frame = CGRect(x: (s - arm) / 2, y: 0, width: arm, height: len)
                case .down: armView.frame = CGRect(x: (s - arm) / 2, y: s - len, width: arm, height: len)
                case .left: armView.frame = CGRect(x: 0, y: (s - arm) / 2, width: len, height: arm)
                default: armView.frame = CGRect(x: s - len, y: (s - arm) / 2, width: len, height: arm)
                }
            }
        }
    }

    private func frame(of element: PadElement) -> CGRect {
        var size = element.size
        if case .dpad = element.kind {
            // Shrink the D-pad on short pads (small phones, landscape) so it never runs into L/R or Select/Start.
            let side = max(90, min(size.width, bounds.height * 0.62, bounds.width * 0.9))
            size = CGSize(width: side, height: side)
        }
        let c = CGPoint(x: element.center.x * bounds.width, y: element.center.y * bounds.height)
        return CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
    }

    // MARK: touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        haptic.prepare()
        for t in touches { touchKeys[ObjectIdentifier(t)] = keys(at: t.location(in: self)) }
        publish()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { touchKeys[ObjectIdentifier(t)] = keys(at: t.location(in: self)) }
        publish()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { touchKeys[ObjectIdentifier(t)] = nil }
        publish()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { touchKeys[ObjectIdentifier(t)] = nil }
        publish()
    }

    func releaseAll() {
        touchKeys = [:]
        publish()
    }

    /// The keys under one finger: the D-pad direction (dominant axis, small dead zone), or the nearest button whose
    /// slightly enlarged frame contains the point.
    private func keys(at p: CGPoint) -> GBAKeys {
        var best: (keys: GBAKeys, distance: CGFloat)?
        for element in elements {
            let f = frame(of: element)
            switch element.kind {
            case .dpad:
                guard f.insetBy(dx: -24, dy: -24).contains(p) else { continue }
                let dx = p.x - f.midX
                let dy = p.y - f.midY
                if max(abs(dx), abs(dy)) < f.width * 0.12 { return [] }
                if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
                return dy > 0 ? .down : .up
            case .button(let k, _, _):
                guard f.insetBy(dx: -14, dy: -14).contains(p) else { continue }
                let d = hypot(p.x - f.midX, p.y - f.midY)
                if best == nil || d < best!.distance { best = (k, d) }
            }
        }
        return best?.keys ?? []
    }

    private func publish() {
        let now = touchKeys.values.reduce(into: GBAKeys()) { $0.formUnion($1) }
        guard now != pressed else { return }
        if !now.subtracting(pressed).isEmpty { haptic.impactOccurred() }
        pressed = now
        for (element, v) in zip(elements, views) {
            if case .button(let k, _, _) = element.kind {
                v.backgroundColor = now.contains(k) ? Self.lit : Self.idle
            }
        }
        for (k, arm) in dpadArms { arm.backgroundColor = now.contains(k) ? Self.lit : Self.idle }
        onKeys?(now)
    }
}
