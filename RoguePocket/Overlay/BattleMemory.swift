import SwiftUI

/// What the foe has shown this battle, for the strip under the picture: the moves it used, its ability once revealed,
/// and stat changes on both sides (the game announces them once and never shows them again). Facts only.
struct BattleFacts: Equatable {
    struct Stage: Equatable, Hashable {
        let name: String
        let change: Int
    }

    var used: [Int] = []
    var ability: String?
    var foeStages: [Stage] = []
    var yourStages: [Stage] = []
}

/// Fed once a second from the live reader's /battle answer, which carries only what the battle has revealed.
final class BattleMemory: ObservableObject {
    @Published private(set) var facts: BattleFacts?

    /// Summary-screen names, in summary-screen order.
    private static let stageNames: [(key: String, name: String)] = [
        ("atk", "Attack"), ("def", "Defense"), ("spa", "Sp. Atk"), ("spd", "Sp. Def"), ("spe", "Speed"),
        ("acc", "Accuracy"), ("eva", "Evasiveness"),
    ]

    func refresh(from battle: [String: Any]?, data: TypeData?) {
        guard let battle else { return }   // a failed read keeps what is shown; only the battle ending clears it
        guard battle["inBattle"] as? Bool == true, let foe = (battle["enemy"] as? [[String: Any]])?.first else {
            if facts != nil { facts = nil }
            return
        }
        // A double battle's strip lists both foes' weaknesses instead of what they have shown.
        if battle["format"] as? String == "double" {
            if facts != nil { facts = nil }
            return
        }
        var next = BattleFacts()
        next.used = foe["revealedMoves"] as? [Int] ?? []
        if let id = foe["revealedAbility"] as? Int, id > 0 { next.ability = data?.abilityName(id) }
        next.foeStages = Self.stages(foe["stages"])
        next.yourStages = Self.stages((battle["player"] as? [[String: Any]])?.first?["stages"])
        if next != facts { facts = next }
    }

    private static func stages(_ raw: Any?) -> [BattleFacts.Stage] {
        guard let dict = raw as? [String: Int] else { return [] }
        return stageNames.compactMap { s in
            guard let v = dict[s.key], v != 0 else { return nil }
            return BattleFacts.Stage(name: s.name, change: v)
        }
    }
}

struct BattleMemoryView: View {
    let facts: BattleFacts
    @ObservedObject var overlay: BattleOverlay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                label("Used")
                if facts.used.isEmpty {
                    Text("???").foregroundStyle(.white.opacity(0.4))
                }
                ForEach(facts.used, id: \.self) { move in
                    HStack(spacing: 3) {
                        if let t = overlay.data?.moveTypeOf(move), let icon = overlay.typeIcons[t] {
                            Image(uiImage: icon).interpolation(.none).resizable().frame(width: 14, height: 14)
                        }
                        Text(overlay.data?.moveName(move) ?? "???")
                    }
                }
            }
            HStack(spacing: 8) {
                label("Ability")
                Text(facts.ability ?? "???").foregroundStyle(.white.opacity(facts.ability == nil ? 0.4 : 0.9))
                stageGroup("Foe", facts.foeStages)
                stageGroup("You", facts.yourStages)
            }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.white.opacity(0.9))
        .lineLimit(1)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.45))
    }

    @ViewBuilder
    private func stageGroup(_ who: String, _ stages: [BattleFacts.Stage]) -> some View {
        if !stages.isEmpty {
            label(who)
            ForEach(stages, id: \.self) { s in
                Text("\(s.name) \(s.change > 0 ? "+" : "\u{2212}")\(abs(s.change))")
                    .foregroundStyle(s.change > 0 ? Color(red: 0.49, green: 0.89, blue: 0.62) : Color(red: 1, green: 0.6, blue: 0.6))
            }
        }
    }
}
