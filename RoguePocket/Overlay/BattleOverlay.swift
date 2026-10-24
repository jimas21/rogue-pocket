import Foundation
import UIKit

/// What the battle overlay draws, in GBA pixels. Facts the player could look up, nothing more: each foe's weaknesses
/// beside its HP box, each damaging move's effectiveness under its name in the move menu, and on the switch screen how
/// hard the foes' own types hit each party member. Singles and doubles.
struct BattleOverlayState: Equatable {
    struct Weakness: Equatable {
        let type: Int
        let multiplier: Double
    }

    /// One foe on the field: battler 1 (the only one in singles; the upper HP box in doubles), then battler 3.
    struct Foe: Equatable {
        let battler: Int
        /// The species the screen shows (an Illusion's disguise while it holds).
        let species: Int
        let types: [Int]
        /// Top-left corner of its HP box (follows it as it slides in); nil while that box is not on screen.
        var box: CGPoint?
        let weaknesses: [Weakness]
    }

    struct MoveTag: Equatable {
        let slot: Int                // 0...3, the move's place in the menu
        let multipliers: [Double]    // one per foe, in `foes` order
    }

    struct PartyHint: Equatable {
        let slot: Int          // 0...5, as the switch screen lists them
        let type: Int          // the foes' type that hits this member hardest
        let multiplier: Double
    }

    var doubles = false
    var foes: [Foe] = []
    /// Your Pokemon's types and the top-left of its HP box (singles; drawn in the box's empty corner).
    var playerTypes: [Int] = []
    var playerBox: CGPoint?
    /// Only while the move menu is open.
    var moveTags: [MoveTag] = []
    /// The switch screen is up: the weaknesses go top left, and members get a hint when that hit is not neutral.
    var partyMenu = false
    var partyHints: [PartyHint] = []
    /// The battler under the cursor while a target is being picked; nil otherwise.
    var aimed: Int?
}

/// What the strip under the picture and the landscape band show in a double battle: the foes the reader last saw
/// (upper HP box first) without their box positions, because nothing there follows a box and a sliding box must not
/// redraw them.
struct FoeBoard: Equatable {
    var foes: [BattleOverlayState.Foe]
    var aimed: Int?
}

/// The game's own type chart and move table, from the Dex the phone keeps (data.js is `window.DEX = {...}`).
final class TypeData {
    let chart: [[Double]]
    private let moveType: [Int]
    private let moveIsStatus: [Bool]
    private let moveName: [String]
    /// Species id -> its types, for an Illusion disguise (the game shows the disguise's species types).
    let speciesTypes: [Int: [Int]]
    private let abilityName: [String]
    /// Species id -> its ability ids [slot 0, slot 1, hidden].
    private let speciesAbilities: [Int: [Int]]
    /// Species id -> the name the Dex gives it.
    private let speciesNames: [Int: String]

    func speciesName(_ id: Int) -> String? { speciesNames[id] }
    func moveName(_ id: Int) -> String? { id > 0 && id < moveName.count ? moveName[id] : nil }
    func moveTypeOf(_ id: Int) -> Int? { id > 0 && id < moveType.count && moveType[id] >= 0 ? moveType[id] : nil }
    func abilityName(_ id: Int) -> String? { id > 0 && id < abilityName.count ? abilityName[id] : nil }

    /// Moves whose type depends on the user, the weather or the terrain: no tag rather than a wrong one.
    private static let variableType: Set<String> = [
        "Hidden Power", "Weather Ball", "Judgment", "Techno Blast", "Multi-Attack", "Tera Blast", "Revelation Dance",
        "Ivy Cudgel", "Terrain Pulse", "Natural Gift", "Aura Wheel", "Raging Bull", "Tera Starstorm", "Struggle",
    ]

    init?(dexData: Data) {
        guard var text = String(data: dexData, encoding: .utf8), let eq = text.firstIndex(of: "=") else { return nil }
        text = String(text[text.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(";") { text.removeLast() }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let chart = obj["chart"] as? [[Double]], chart.count >= 19,
              let moves = obj["moves"] as? [[Any]] else { return nil }
        self.chart = chart
        moveName = moves.map { $0.first as? String ?? "" }
        moveType = moves.map { $0.count > 1 ? ($0[1] as? Int ?? -1) : -1 }
        moveIsStatus = moves.map { $0.count > 6 ? ($0[6] as? Int ?? 2) == 2 : true }
        var types: [Int: [Int]] = [:]
        for sp in obj["species"] as? [[String: Any]] ?? [] {
            if let id = sp["id"] as? Int, let t = sp["types"] as? [Int] { types[id] = t }
        }
        speciesTypes = types
        abilityName = (obj["abilities"] as? [[Any]] ?? []).map { $0.first as? String ?? "" }
        var abilities: [Int: [Int]] = [:]
        for sp in obj["species"] as? [[String: Any]] ?? [] {
            if let id = sp["id"] as? Int, let ab = sp["ab"] as? [Int] { abilities[id] = ab }
        }
        speciesAbilities = abilities
        var names: [Int: String] = [:]
        for sp in obj["species"] as? [[String: Any]] ?? [] {
            if let id = sp["id"] as? Int, let name = sp["name"] as? String { names[id] = name }
        }
        speciesNames = names
    }

    /// The name of a party member's ability: its slot's ability, or slot 0's when that slot is empty.
    func memberAbility(species: Int, abilityNum: Int) -> String? {
        guard let ab = speciesAbilities[species], !ab.isEmpty else { return nil }
        let id = abilityNum < ab.count && ab[abilityNum] > 0 ? ab[abilityNum] : ab[0]
        return abilityName(id)
    }

    /// Abilities that change how hard a type hits their owner (the same table the Dex uses).
    private static let abilityMods: [String: [Int: Double]] = [
        "Levitate": [4: 0], "Earth Eater": [4: 0], "Flash Fire": [10: 0], "Well-Baked Body": [10: 0],
        "Water Absorb": [11: 0], "Storm Drain": [11: 0], "Dry Skin": [11: 0, 10: 1.25],
        "Volt Absorb": [13: 0], "Lightning Rod": [13: 0], "Motor Drive": [13: 0], "Sap Sipper": [12: 0],
        "Thick Fat": [10: 0.5, 15: 0.5], "Heatproof": [10: 0.5], "Water Bubble": [10: 0.5], "Purifying Salt": [7: 0.5],
        "Fluffy": [10: 2],
    ]

    /// How hard an attacking type hits one of the player's own Pokemon, its known ability included.
    func defense(_ attack: Int, types: [Int], ability: String?) -> Double {
        var m = multiplier(attack, against: types)
        if let ability, let mod = Self.abilityMods[ability]?[attack] { m *= mod }
        if ability == "Wonder Guard", m <= 1 { m = 0 }
        return m
    }

    /// Damage multiplier of an attacking type against a battler's types (the game skips a repeated type and an
    /// empty third type, TYPE_MYSTERY = 9).
    func multiplier(_ attack: Int, against types: [Int]) -> Double {
        var m = 1.0
        var seen: [Int] = []
        guard attack >= 0, attack < chart.count else { return 1 }
        for t in types where t != 9 && !seen.contains(t) && t < chart[attack].count {
            seen.append(t)
            m *= chart[attack][t]
        }
        return m
    }

    /// The multiplier a damaging move shows against these types, or nil for status moves and moves of no fixed type.
    func moveMultiplier(_ move: Int, against types: [Int]) -> Double? {
        guard move > 0, move < moveType.count, !moveIsStatus[move], moveType[move] >= 0,
              !Self.variableType.contains(moveName[move]) else { return nil }
        var m = multiplier(moveType[move], against: types)
        switch moveName[move] {
        case "Freeze-Dry" where types.contains(11):        // super effective on Water whatever the chart says
            m = m / chart[15][11] * 2
        case "Flying Press":                                // Fighting and Flying at once
            m *= multiplier(2, against: types)
        case "Thousand Arrows" where types.contains(2):     // hits Flying types for normal damage
            m = multiplier(4, against: types.filter { $0 != 2 })
        default:
            break
        }
        return m
    }
}

/// Reads the battle screen from emulated memory. Data addresses are the stock Emerald Rogue EX v2.2.1 map's and match
/// every build seen so far; function addresses (BattleMainCB2, CB2_UpdatePartyMenu, HandleInputChooseMove) differ
/// between builds, so each known build's are listed (read from the running game).
enum BattleReader {
    private static let gMain: UInt32 = 0x0300_14B4               // .callback2 at +4, .inBattle bit 1 of +0x439
    private static let battleMainCB2: Set<UInt32> = [0x0807_E6A1, 0x0807_FCAD]
    private static let partyMenuCB2: Set<UInt32> = [0x0815_B225, 0x0815_DF99]   // the switch screen in battle
    private static let playerParty: UInt32 = 0x0203_6C7C          // struct Pokemon[6]; gPlayerPartyCount 3 bytes before
    private static let controllerFuncs: UInt32 = 0x0300_2244     // gBattlerControllerFuncs[4]
    private static let handleInputChooseMove: Set<UInt32> = [0x0805_A6C5, 0x0805_BB19]
    /// The target step: choosing which Pokemon a move hits. A build not listed here keeps both foes bright there.
    private static let handleInputChooseTarget: Set<UInt32> = [0x0805_B3B1]
    private static let battlersCount: UInt32 = 0x0201_C33C
    private static let battlerPartyIndexes: UInt32 = 0x0201_C340 // u16[4]
    private static let battleMons: UInt32 = 0x0201_C358          // struct BattlePokemon[4], 96 bytes each
    private static let battleStructPtr: UInt32 = 0x0201_C83C     // ->illusion[4] at +660, 8 bytes each
    private static let enemyParty: UInt32 = 0x0203_6EEC          // struct Pokemon[6], 104 bytes, personality at +0
    private static let healthboxSpriteIds: UInt32 = 0x0300_22DC
    private static let multiUsePlayerCursor: UInt32 = 0x0300_22E0 // u8, the battler under the target cursor
    private static let sprites: UInt32 = 0x0203_C690             // struct Sprite[64], 68 bytes each

    /// nil outside a battle. `previous` is kept while a foe's slot is mid-swap (see below).
    static func read(_ core: MGBACore, data: TypeData, previous: BattleOverlayState?) -> BattleOverlayState? {
        guard let main = core.readMemory(address: gMain, length: 0x43A), main[0x439] & 2 != 0,
              battleMainCB2.contains(u32(main, 4)) || partyMenuCB2.contains(u32(main, 4)),
              let count = core.readMemory(address: battlersCount, length: 1)?.first, count == 2 || count == 4,
              let mons = core.readMemory(address: battleMons, length: 96 * Int(count)),
              let indexes = core.readMemory(address: battlerPartyIndexes, length: 8) else { return nil }
        var state = BattleOverlayState()
        state.partyMenu = partyMenuCB2.contains(u32(main, 4))
        state.doubles = count == 4
        let structPtr = core.readMemory(address: battleStructPtr, length: 4).map { u32($0, 0) }
        let boxIds = core.readMemory(address: healthboxSpriteIds, length: 4)

        for b in state.doubles ? [1, 3] : [1] {
            let mon = Array(mons[(96 * b)..<(96 * b + 96)])
            let species = Int(u16(mon, 0))
            guard species > 0, u16(mon, 42) > 0 else { continue }   // not there, or fainted

            // The AI copies party members into gBattleMons while it weighs a switch. The real occupant has the
            // personality of the party slot gBattlerPartyIndexes names; a read mid-swap keeps what was shown.
            let idx = Int(u16(indexes, 2 * b))
            guard idx < 6, let slot = core.readMemory(address: enemyParty + UInt32(idx * 104), length: 4) else { continue }
            if u32(slot, 0) != u32(mon, 76) { return previous }

            // Illusion: while it holds, the game rates moves against the disguise's species types, so the overlay
            // does too. Hiding anything would itself give the disguise away.
            var types = [Int(mon[34]), Int(mon[35]), Int(mon[36])]
            var shown = species
            if let ptr = structPtr,
               let il = core.readMemory(address: ptr &+ 660 &+ UInt32(8 * b), length: 4),
               il[0] != 0, il[1] != 0, il[2] == 0, Int(il[3]) < 6,
               let disguise = partyMon(core, base: enemyParty, slot: Int(il[3]))?.species,
               let disguiseTypes = data.speciesTypes[disguise] {
                types = disguiseTypes
                shown = disguise
            }

            // Its HP box: the sprite must be in use, shown, and owned by this battler (at a battle's start the id
            // slots still point at the previous scene's sprites). The switch screen reuses those sprites: skip it.
            var box: CGPoint?
            if !state.partyMenu, let ids = boxIds, ids[b] < 64,
               let sprite = core.readMemory(address: sprites + UInt32(ids[b]) * 68, length: 68) {
                let flags = u16(sprite, 62)
                if flags & 1 != 0, flags & 4 == 0, Int(s16(sprite, 58)) == b {
                    let x = Int(s16(sprite, 0x20)) + Int(s16(sprite, 0x24)) + Int(Int8(bitPattern: sprite[0x28]))
                    let y = Int(s16(sprite, 0x22)) + Int(s16(sprite, 0x26)) + Int(Int8(bitPattern: sprite[0x29]))
                    box = CGPoint(x: x, y: y)
                }
            }
            let weak = (0..<19).compactMap { t -> BattleOverlayState.Weakness? in
                guard t != 9 else { return nil }
                let m = data.multiplier(t, against: types)
                return m > 1 ? .init(type: t, multiplier: m) : nil
            }.sorted { $0.multiplier != $1.multiplier ? $0.multiplier > $1.multiplier : $0.type < $1.type }
            state.foes.append(.init(battler: b, species: shown, types: types, box: box, weaknesses: weak))
        }
        guard !state.foes.isEmpty else { return nil }

        if !state.doubles, !state.partyMenu, u16(Array(mons[0..<96]), 0) > 0 {
            state.playerTypes = [Int(mons[34]), Int(mons[35]), Int(mons[36])]
            if let ids = boxIds, ids[0] < 64,
               let sprite = core.readMemory(address: sprites + UInt32(ids[0]) * 68, length: 68) {
                let flags = u16(sprite, 62)
                if flags & 1 != 0, flags & 4 == 0, s16(sprite, 58) == 0 {
                    let x = Int(s16(sprite, 0x20)) + Int(s16(sprite, 0x24)) + Int(Int8(bitPattern: sprite[0x28]))
                    let y = Int(s16(sprite, 0x22)) + Int(s16(sprite, 0x26)) + Int(Int8(bitPattern: sprite[0x29]))
                    state.playerBox = CGPoint(x: x, y: y)
                }
            }
        }

        // The switch screen lists gPlayerParty in its stored order (the game reorders the party for the menu).
        if state.partyMenu {
            let party = min(Int(core.readMemory(address: playerParty - 3, length: 1)?.first ?? 0), 6)
            let attacks = state.foes.flatMap(\.types).reduce(into: [Int]()) { list, t in
                if t != 9 && !list.contains(t) { list.append(t) }
            }
            for slot in 0..<party {
                guard let mon = partyMon(core, base: playerParty, slot: slot), !mon.isEgg,
                      let memberTypes = data.speciesTypes[mon.species] else { continue }
                let ability = data.memberAbility(species: mon.species, abilityNum: mon.abilityNum)
                let hits = attacks.map { (type: $0, m: data.defense($0, types: memberTypes, ability: ability)) }
                if let worst = hits.max(by: { $0.m < $1.m }), worst.m != 1 {
                    state.partyHints.append(.init(slot: slot, type: worst.type, multiplier: worst.m))
                }
            }
            return state
        }

        // The move menu (battler 0, or 2 for the second Pokemon in doubles): every damaging move gets its multiplier
        // against each foe. The menu stays up while a target is picked, so its marks stay too, and at that step the
        // game's own target cursor says which battler is aimed at.
        if let funcs = core.readMemory(address: controllerFuncs, length: 16),
           let me = (state.doubles ? [0, 2] : [0]).first(where: {
               handleInputChooseMove.contains(u32(funcs, 4 * $0)) || handleInputChooseTarget.contains(u32(funcs, 4 * $0))
           }) {
            let mine = Array(mons[(96 * me)..<(96 * me + 96)])
            for i in 0..<4 {
                let move = Int(u16(mine, 12 + 2 * i))
                let ms = state.foes.compactMap { data.moveMultiplier(move, against: $0.types) }
                if ms.count == state.foes.count { state.moveTags.append(.init(slot: i, multipliers: ms)) }
            }
            if handleInputChooseTarget.contains(u32(funcs, 4 * me)),
               let cursor = core.readMemory(address: multiUsePlayerCursor, length: 1)?.first, cursor < 4 {
                state.aimed = Int(cursor)
            }
        }
        return state
    }

    /// One line for the debug readout: each check the reader makes, with what it found.
    static func probe(_ core: MGBACore) -> String {
        guard let main = core.readMemory(address: gMain, length: 0x43A) else { return "gMain unreadable" }
        let cb2 = u32(main, 4)
        let screen = battleMainCB2.contains(cb2) ? "battle" : partyMenuCB2.contains(cb2) ? "switch" : String(cb2, radix: 16)
        var out = "cb2 \(screen) inBattle \(main[0x439] & 2 != 0)"
        guard let count = core.readMemory(address: battlersCount, length: 1)?.first else { return out }
        out += " battlers \(count)"
        guard let mon = core.readMemory(address: battleMons + 96, length: 96),
              let indexes = core.readMemory(address: battlerPartyIndexes, length: 4) else { return out }
        let idx = Int(u16(indexes, 2))
        let match = idx < 6 ? core.readMemory(address: enemyParty + UInt32(idx * 104), length: 4).map { u32($0, 0) == u32(mon, 76) } : nil
        out += " foe \(u16(mon, 0)) hp \(u16(mon, 42)) slot \(idx) same \(match.map { String($0) } ?? "?")"
        if let ids = core.readMemory(address: healthboxSpriteIds, length: 4), ids[1] < 64,
           let sprite = core.readMemory(address: sprites + UInt32(ids[1]) * 68, length: 68) {
            out += " box id \(ids[1]) flags \(String(u16(sprite, 62), radix: 16)) owner \(s16(sprite, 58))"
        }
        return out
    }

    /// True while the game is in a battle (any screen of it: the bag and the summary included); false when unreadable.
    static func inBattle(_ core: MGBACore) -> Bool {
        guard let byte = core.readMemory(address: gMain + 0x439, length: 1)?.first else { return false }
        return byte & 2 != 0
    }

    /// Substruct order (growth, attacks, EVs, misc) by personality % 24.
    private static let substructOrder: [[Int]] = [
        [0, 1, 2, 3], [0, 1, 3, 2], [0, 2, 1, 3], [0, 3, 1, 2], [0, 2, 3, 1], [0, 3, 2, 1], [1, 0, 2, 3], [1, 0, 3, 2],
        [2, 0, 1, 3], [3, 0, 1, 2], [2, 0, 3, 1], [3, 0, 2, 1], [1, 2, 0, 3], [1, 3, 0, 2], [2, 1, 0, 3], [3, 1, 0, 2],
        [2, 3, 0, 1], [3, 2, 0, 1], [1, 2, 3, 0], [1, 3, 2, 0], [2, 1, 3, 0], [3, 1, 2, 0], [2, 3, 1, 0], [3, 2, 1, 0],
    ]

    /// Species, ability slot and egg flag of a party member: decrypts its substructs (same rules as the live reader).
    private static func partyMon(_ core: MGBACore, base: UInt32, slot: Int) -> (species: Int, abilityNum: Int, isEgg: Bool)? {
        guard let b = core.readMemory(address: base + UInt32(slot * 104), length: 80) else { return nil }
        let personality = u32(b, 0), key = personality ^ u32(b, 4)
        var secure = [UInt8](repeating: 0, count: 48)
        for i in 0..<12 {
            let w = u32(b, 32 + i * 4) ^ key
            for k in 0..<4 { secure[i * 4 + k] = UInt8((w >> (8 * UInt32(k))) & 0xFF) }
        }
        var sum: UInt32 = 0
        for j in 0..<24 { sum &+= UInt32(u16(secure, j * 2)) }
        guard UInt16(sum & 0xFFFF) == u16(b, 28) else { return nil }
        let order = substructOrder[Int(personality % 24)]
        let species = Int(u32(secure, order[0] * 12) & 0x7FF)
        let misc = u32(secure, order[3] * 12 + 8)
        guard species > 0 else { return nil }
        return (species, Int((misc >> 29) & 3), (b[19] >> 2) & 1 != 0)
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    private static func s16(_ b: [UInt8], _ o: Int) -> Int16 { Int16(bitPattern: u16(b, o)) }
    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
}

/// Keeps the overlay in step with the game: the emulator calls `framesDidRun` after each batch of frames.
/// Main thread only (mGBA is).
final class BattleOverlay: ObservableObject {
    @Published private(set) var state: BattleOverlayState?
    @Published private(set) var typeIcons: [Int: UIImage] = [:]
    /// Both foes of a double battle, kept for the whole fight: the reader returns nothing on the bag and summary
    /// screens, and the strip must not blink out and back. Nil in singles and outside a battle.
    @Published private(set) var board: FoeBoard?
    private(set) var data: TypeData?
    private var loading = false
    private var lastAttempt = Date.distantPast
    private var tick = 0
    private var foeSprites: [Int: UIImage] = [:]

    /// A foe's picture from the Dex download (sprites/<species>.png), to tell two foes apart on the switch screen.
    func foeSprite(_ species: Int) -> UIImage? {
        if let image = foeSprites[species] { return image }
        guard let raw = DexStore.shared.file(at: "sprites/\(species).png"), let image = UIImage(data: raw) else { return nil }
        foeSprites[species] = image
        return image
    }

    /// What the reader sees, for Debug > Show debug info (refreshed about three times a second).
    @Published private(set) var debugLine = ""

    func framesDidRun(_ core: MGBACore) {
        tick += 1
        if tick % 30 == 0 {
            var line = "overlay: data \(data != nil) icons \(typeIcons.count) | " + BattleReader.probe(core)
            if let s = state {
                let box = s.foes.first?.box.map { "\(Int($0.x)),\(Int($0.y))" } ?? "none"
                line += " | foes \(s.foes.count) box \(box) weak \(s.foes.first?.weaknesses.count ?? 0) tags \(s.moveTags.count)"
            } else {
                line += " | no state"
            }
            if line != debugLine { debugLine = line }
        }
        guard tick % 3 == 0 else { return }   // ~20 reads a second is plenty
        guard let data else { return loadIfNeeded() }
        let next = BattleReader.read(core, data: data, previous: state)
        if next != state { state = next }
        let held = heldBoard(after: next, core: core)
        if held != board { board = held }
    }

    /// The board for a read: built from a doubles read, kept across screens the reader skips while the battle is
    /// still on, dropped when the battle ends or a singles battle is read.
    private func heldBoard(after next: BattleOverlayState?, core: MGBACore) -> FoeBoard? {
        if let next {
            guard next.doubles else { return nil }
            let foes = next.foes.map { foe -> BattleOverlayState.Foe in
                var copy = foe
                copy.box = nil
                return copy
            }
            return FoeBoard(foes: foes, aimed: next.aimed)
        }
        if let board, BattleReader.inBattle(core) { return board }
        return nil
    }

    /// The type data and icons come with the Dex download (the icons are game art, kept out of the app itself).
    private func loadIfNeeded() {
        guard !loading, Date().timeIntervalSince(lastAttempt) > 10 else { return }
        loading = true
        lastAttempt = Date()
        DispatchQueue.global(qos: .utility).async {
            let store = DexStore.shared
            let data = store.file(at: "data.js").flatMap { TypeData(dexData: $0) }
            var icons: [Int: UIImage] = [:]
            for t in 0..<19 {
                if let raw = store.file(at: "pocket/types/\(t).png"), let image = UIImage(data: raw) { icons[t] = image }
            }
            DispatchQueue.main.async {
                self.data = data
                self.typeIcons = icons
                self.loading = false
            }
        }
    }
}
