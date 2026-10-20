import Foundation
import UIKit

/// What the battle overlay draws, in GBA pixels. Facts the player could look up, nothing more: the enemy's
/// weaknesses above its HP box, and each damaging move's effectiveness under its name in the move menu.
struct BattleOverlayState: Equatable {
    struct Weakness: Equatable {
        let type: Int
        let multiplier: Double
    }

    struct MoveTag: Equatable {
        let slot: Int          // 0...3, the move's place in the menu
        let multiplier: Double
    }

    /// Top-left corner of the enemy's HP box (follows it as it slides in); nil while it is not on screen.
    var enemyBox: CGPoint?
    var weaknesses: [Weakness] = []
    /// Only while the move menu is open.
    var moveTags: [MoveTag] = []
}

/// The game's own type chart and move table, from the Dex the phone keeps (data.js is `window.DEX = {...}`).
final class TypeData {
    let chart: [[Double]]
    private let moveType: [Int]
    private let moveIsStatus: [Bool]
    private let moveName: [String]

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

/// Reads the battle screen from emulated memory. Addresses are from the stock Emerald Rogue EX v2.2.1 ROM; the
/// function pointers (BattleMainCB2, HandleInputChooseMove) were read from the running game.
enum BattleReader {
    private static let gMain: UInt32 = 0x0300_14B4               // .callback2 at +4, .inBattle bit 1 of +0x439
    private static let battleMainCB2: UInt32 = 0x0807_E6A1
    private static let controllerFuncs: UInt32 = 0x0300_2244     // gBattlerControllerFuncs[4]
    private static let handleInputChooseMove: UInt32 = 0x0805_A6C5
    private static let battlersCount: UInt32 = 0x0201_C33C
    private static let battlerPartyIndexes: UInt32 = 0x0201_C340 // u16[4]
    private static let battleMons: UInt32 = 0x0201_C358          // struct BattlePokemon[4], 96 bytes each
    private static let battleStructPtr: UInt32 = 0x0201_C83C     // ->illusion[4] at +660, 8 bytes each
    private static let enemyParty: UInt32 = 0x0203_6EEC          // struct Pokemon[6], 104 bytes, personality at +0
    private static let healthboxSpriteIds: UInt32 = 0x0300_22DC
    private static let sprites: UInt32 = 0x0203_C690             // struct Sprite[64], 68 bytes each

    /// nil outside a singles battle. `previous` is kept when the enemy slot is mid-swap (see below).
    static func read(_ core: MGBACore, data: TypeData, previous: BattleOverlayState?) -> BattleOverlayState? {
        guard let main = core.readMemory(address: gMain, length: 0x43A),
              u32(main, 4) == battleMainCB2, main[0x439] & 2 != 0,
              core.readMemory(address: battlersCount, length: 1)?.first == 2,
              let mons = core.readMemory(address: battleMons, length: 96 * 2) else { return nil }
        let enemy = Array(mons[96..<192])

        // The AI copies party members into gBattleMons while it weighs a switch. The real occupant has the
        // personality of the party slot gBattlerPartyIndexes names; a read mid-swap keeps what was shown.
        guard let idx = core.readMemory(address: battlerPartyIndexes + 2, length: 2).map({ Int(u16($0, 0)) }),
              idx < 6, let slot = core.readMemory(address: enemyParty + UInt32(idx * 104), length: 4) else { return nil }
        if u32(slot, 0) != u32(enemy, 76) { return previous }

        var state = BattleOverlayState()
        let types = [Int(enemy[34]), Int(enemy[35]), Int(enemy[36])]

        // The enemy's HP box: its sprite must be in use, shown, and owned by battler 1 (at a battle's start the id
        // slots still point at the previous scene's sprites).
        if let ids = core.readMemory(address: healthboxSpriteIds, length: 2), ids[1] < 64,
           let sprite = core.readMemory(address: sprites + UInt32(ids[1]) * 68, length: 68) {
            let flags = u16(sprite, 62)
            if flags & 1 != 0, flags & 4 == 0, s16(sprite, 58) == 1 {
                let x = Int(s16(sprite, 0x20)) + Int(s16(sprite, 0x24)) + Int(Int8(bitPattern: sprite[0x28]))
                let y = Int(s16(sprite, 0x22)) + Int(s16(sprite, 0x26)) + Int(Int8(bitPattern: sprite[0x29]))
                state.enemyBox = CGPoint(x: x, y: y)
            }
        }

        // Illusion: the game shows the disguise's types, and the real ones would give it away. Show nothing.
        var disguised = false
        if let ptr = core.readMemory(address: battleStructPtr, length: 4).map({ u32($0, 0) }),
           let il = core.readMemory(address: ptr &+ 660 &+ 8, length: 4) {
            disguised = il[0] != 0 && il[1] != 0 && il[2] == 0
        }
        if !disguised {
            state.weaknesses = (0..<19).compactMap { t -> BattleOverlayState.Weakness? in
                guard t != 9 else { return nil }
                let m = data.multiplier(t, against: types)
                return m > 1 ? .init(type: t, multiplier: m) : nil
            }.sorted { $0.multiplier != $1.multiplier ? $0.multiplier > $1.multiplier : $0.type < $1.type }
        }

        // The move menu (battler 0 in singles): every damaging move gets its multiplier against the enemy.
        if !disguised, let funcs = core.readMemory(address: controllerFuncs, length: 4), u32(funcs, 0) == handleInputChooseMove {
            let mine = Array(mons[0..<96])
            for i in 0..<4 {
                let move = Int(u16(mine, 12 + 2 * i))
                if let m = data.moveMultiplier(move, against: types) {
                    state.moveTags.append(.init(slot: i, multiplier: m))
                }
            }
        }
        return state
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
    private var data: TypeData?
    private var loading = false
    private var lastAttempt = Date.distantPast
    private var tick = 0

    func framesDidRun(_ core: MGBACore) {
        tick += 1
        guard tick % 3 == 0 else { return }   // ~20 reads a second is plenty
        guard let data else { return loadIfNeeded() }
        let next = BattleReader.read(core, data: data, previous: state)
        if next != state { state = next }
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
