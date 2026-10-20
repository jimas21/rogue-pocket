import SwiftUI
import UIKit

// On-screen controls. One UIKit view per pad tracks every finger itself (touchesBegan/Moved/Ended), the way
// emulator front ends do it: true multi-touch, a thumb can slide across the D-pad or from B onto A, and nothing
// depends on SwiftUI gesture arbitration between sibling views. Controls are placed by fraction of the pad's
// size, so the layout fits any screen width.

/// One control, placed in its pad: `center` is a fraction of the pad's size, `size` is in points.
struct PadElement {
    enum Kind {
        case button(GBAKeys, String, round: Bool)
        case dpad
        case fastForward
    }

    let kind: Kind
    let center: CGPoint
    let size: CGSize

    static func button(_ keys: GBAKeys, _ label: String, x: CGFloat, y: CGFloat, w: CGFloat = 64, h: CGFloat = 64,
                       round: Bool = true) -> PadElement {
        PadElement(kind: .button(keys, label, round: round), center: CGPoint(x: x, y: y), size: CGSize(width: w, height: h))
    }

    static func fastForward(x: CGFloat, y: CGFloat) -> PadElement {
        PadElement(kind: .fastForward, center: CGPoint(x: x, y: y), size: CGSize(width: 56, height: 32))
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
        .fastForward(x: 0.5, y: 0.09),
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
        .fastForward(x: 0.5, y: 0.25),
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
        view.onFastForward = { on in emu.setFastForward(on) }
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
    /// Fast forward: a quick tap toggles it, a hold runs it only while held.
    var onFastForward: ((Bool) -> Void)?

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
            case .fastForward:
                let b = UILabel()
                b.text = "\u{25B6}\u{25B6}"
                b.textAlignment = .center
                b.textColor = .white
                b.font = .systemFont(ofSize: 12, weight: .heavy)
                b.backgroundColor = Self.idle
                b.layer.cornerRadius = element.size.height / 2
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

    /// What a finger is bound to. A finger that lands on (or near) the D-pad stays the D-pad until it lifts, however
    /// far the thumb drifts, so a rolling thumb never drops the direction. Other fingers can slide between buttons.
    private enum Binding {
        case dpad(CGRect)
        case buttons
        case fastForward(Date)
    }

    private var ffLatched = false
    private var ffHeld = false
    private var ffShown = false

    private var bindings: [ObjectIdentifier: Binding] = [:]

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        haptic.prepare()
        for t in touches {
            let p = t.location(in: self)
            let id = ObjectIdentifier(t)
            if fastForwardHit(p) {
                bindings[id] = .fastForward(Date())
                ffHeld = true
                touchKeys[id] = []
            } else if let pad = dpadFrame(near: p) {
                bindings[id] = .dpad(pad)
                touchKeys[id] = direction(at: p, in: pad)
            } else {
                bindings[id] = .buttons
                touchKeys[id] = button(at: p)
            }
        }
        publish()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            let id = ObjectIdentifier(t)
            switch bindings[id] {
            case .dpad(let pad): touchKeys[id] = direction(at: p, in: pad)
            case .fastForward: break
            default: touchKeys[id] = button(at: p)
            }
        }
        publish()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        lift(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        lift(touches)
    }

    private func lift(_ touches: Set<UITouch>) {
        for t in touches {
            if case .fastForward(let began) = bindings[ObjectIdentifier(t)] {
                ffHeld = false
                if Date().timeIntervalSince(began) < 0.3 { ffLatched.toggle() } // a tap toggles; a hold was momentary
            }
            touchKeys[ObjectIdentifier(t)] = nil
            bindings[ObjectIdentifier(t)] = nil
        }
        publish()
    }

    func releaseAll() {
        touchKeys = [:]
        bindings = [:]
        ffHeld = false
        ffLatched = false
        publish()
    }

    private func fastForwardHit(_ p: CGPoint) -> Bool {
        elements.contains { element in
            guard case .fastForward = element.kind else { return false }
            return frame(of: element).insetBy(dx: -10, dy: -10).contains(p)
        }
    }

    /// The D-pad catches a touch anywhere in a generous zone around it (40 pt beyond its drawn edge), unless the point
    /// is clearly on a button.
    private func dpadFrame(near p: CGPoint) -> CGRect? {
        for element in elements {
            guard case .dpad = element.kind else { continue }
            let f = frame(of: element)
            if f.insetBy(dx: -40, dy: -40).contains(p), button(at: p, slack: 0).isEmpty { return f }
        }
        return nil
    }

    /// Direction from the D-pad's centre. Eight ways, but the diagonals are narrow (30 degrees each) so a thumb
    /// aimed at a cardinal direction stays cardinal; a small dead zone in the middle presses nothing.
    private func direction(at p: CGPoint, in pad: CGRect) -> GBAKeys {
        let dx = p.x - pad.midX
        let dy = p.y - pad.midY
        if hypot(dx, dy) < pad.width * 0.09 { return [] }
        var angle = atan2(-dy, dx) * 180 / .pi // 0 = right, 90 = up
        if angle < 0 { angle += 360 }
        switch angle {
        case 0..<30, 330..<360: return .right
        case 30..<60: return [.up, .right]
        case 60..<120: return .up
        case 120..<150: return [.up, .left]
        case 150..<210: return .left
        case 210..<240: return [.down, .left]
        case 240..<300: return .down
        default: return [.down, .right]
        }
    }

    /// The nearest button whose enlarged frame contains the point.
    private func button(at p: CGPoint, slack: CGFloat = 16) -> GBAKeys {
        var best: (keys: GBAKeys, distance: CGFloat)?
        for element in elements {
            guard case .button(let k, _, _) = element.kind else { continue }
            let f = frame(of: element)
            guard f.insetBy(dx: -slack, dy: -slack).contains(p) else { continue }
            let d = hypot(p.x - f.midX, p.y - f.midY)
            if best == nil || d < best!.distance { best = (k, d) }
        }
        return best?.keys ?? []
    }

    private func publish() {
        let ff = ffHeld || ffLatched
        if ff != ffShown {
            ffShown = ff
            for (element, v) in zip(elements, views) {
                if case .fastForward = element.kind { v.backgroundColor = ff ? Self.lit : Self.idle }
            }
            if ff { haptic.impactOccurred() }
            onFastForward?(ff)
        }
        let now = touchKeys.values.reduce(into: GBAKeys()) { $0.formUnion($1) }
        guard now != pressed else { return }
        if !now.isEmpty, now != pressed { haptic.impactOccurred() } // also on each D-pad direction change
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
