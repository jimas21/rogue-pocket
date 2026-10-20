import AVFoundation
import Combine
import GameController
import SwiftUI
import UIKit

/// Owns the running game: the core, the display-link clock, audio, input, the files, and the debug numbers.
/// Everything here runs on the main thread: the display link fires there, UI callbacks are there, and so
/// mGBA (which is not thread-safe) is only ever touched from one thread. The runFrame timings in the debug
/// line show whether that stays fast enough; if not, the core moves to its own thread.
final class Emulator: ObservableObject {
    // UI state
    @Published private(set) var status = "No ROM loaded. Open the menu (top right) and choose Load ROM."
    @Published private(set) var romName: String?
    @Published private(set) var debugText = ""
    @Published private(set) var benchText = ""
    /// Fast forward is on (held or toggled from the pad). Speed comes from the "ffSpeed" setting (2-4x, default 3).
    @Published private(set) var fastForward = false
    @Published var muted = false {
        didSet {
            audio.setMuted(muted)
            if !settingAutoMute { autoMuted = false } // the player chose; stop following other apps
        }
    }
    /// Muted because another app was playing (an audiobook, music); unmutes when that stops.
    private var autoMuted = false
    private var settingAutoMute = false

    weak var screen: GameScreenView?
    /// What the battle overlay draws over the picture; read from memory after each batch of frames.
    let overlay = BattleOverlay()
    private(set) var core: MGBACore?

    // Constants
    /// One GBA frame is 280896 cycles of a 16.777216 MHz clock: about 16.7427 ms (59.7275 fps).
    private static let frameDuration = 280_896.0 / 16_777_216.0
    private static let scratchFrames = 16_384
    private static let lastROMKey = "lastROM"
    /// gPlayerPartyCount in the stock v2.2.1 map; shown only as a live readMemory check.
    private static let partyCountAddress: UInt32 = 0x0203_6C79

    // Clock + stats
    private let audio = AudioOutput()
    private let linkTarget = LinkTarget()
    private var link: CADisplayLink?
    private var visible = false
    private var inForeground = true
    private var lastTimestamp: CFTimeInterval = 0
    private var accumulator = 0.0
    private var winStart: CFTimeInterval = 0
    private var winTicks = 0
    private var winFrames = 0
    private var winRunSum = 0.0
    private var winRunMax = 0.0
    private var winKeysSent: GBAKeys = []
    private var winKeysCore: GBAKeys = []
    private var ewramAddressAtOpen: UInt = 0

    // Input
    private var touchKeys: GBAKeys = []
    private var touchSources: [String: GBAKeys] = [:]
    private var padKeys: GBAKeys = []

    private(set) var romURL: URL?
    private let audioScratch: UnsafeMutablePointer<Int16>

    init() {
        audioScratch = UnsafeMutablePointer<Int16>.allocate(capacity: Emulator.scratchFrames * 2)
        linkTarget.owner = self
        // Make the app's folder show up in the Files app (it needs content) and give ROMs and saves an obvious home.
        for dir in [romsDir, savesDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        observeControllers()
        NotificationCenter.default.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.followOtherAudio()
        }
    }

    /// Game sound steps aside while another app plays audio, and comes back when it stops (unless the player
    /// set Mute themselves).
    func followOtherAudio() {
        let other = AVAudioSession.sharedInstance().isOtherAudioPlaying
        if other && !muted {
            settingAutoMute = true
            muted = true
            settingAutoMute = false
            autoMuted = true
        } else if !other && autoMuted {
            settingAutoMute = true
            muted = false
            settingAutoMute = false
            autoMuted = false
        }
    }

    deinit {
        audioScratch.deallocate()
    }

    // MARK: - Files

    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var romsDir: URL { documents.appendingPathComponent("ROMs", isDirectory: true) }
    private var savesDir: URL { documents.appendingPathComponent("Saves", isDirectory: true) }

    private func saveURL(for rom: URL) -> URL {
        savesDir.appendingPathComponent(rom.deletingPathExtension().lastPathComponent + ".sav")
    }

    private func isInTemp(_ url: URL) -> Bool {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        return url.resolvingSymlinksInPath().path.hasPrefix(temp)
    }

    /// ROMs already on the phone: dropped into the app's folder in the Files app (On My iPhone > Rogue Pocket)
    /// either at its top level or in ROMs/, or copied there by an earlier "Load ROM".
    func localROMs() -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        for dir in [documents, romsDir] {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            found += items.filter { $0.pathExtension.lowercased() == "gba" }
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// From the document picker (copied into our tmp by the system). Copies it into Documents/ROMs and starts it.
    func loadROM(from picked: URL) {
        closeCore()
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: romsDir, withIntermediateDirectories: true)
            let dest = romsDir.appendingPathComponent(picked.lastPathComponent)
            if picked.resolvingSymlinksInPath().path != dest.resolvingSymlinksInPath().path {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: picked, to: dest)
            }
            if isInTemp(picked) { try? fm.removeItem(at: picked) }
            try open(rom: dest)
        } catch {
            status = "Could not load ROM: \(error.localizedDescription)"
        }
    }

    func openLocal(_ rom: URL) {
        closeCore()
        do {
            try open(rom: rom)
        } catch {
            status = "Could not load ROM: \(error.localizedDescription)"
        }
    }

    /// Replaces the battery save for the loaded ROM with a file from Files, keeping the old one under
    /// Saves/Backups, then restarts the game on the new save.
    func importSave(from picked: URL) {
        guard let rom = romURL else {
            status = "Load a ROM first; a save belongs to a ROM."
            return
        }
        closeCore()
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: savesDir, withIntermediateDirectories: true)
            let dest = saveURL(for: rom)
            if fm.fileExists(atPath: dest.path) {
                let backups = savesDir.appendingPathComponent("Backups", isDirectory: true)
                try fm.createDirectory(at: backups, withIntermediateDirectories: true)
                let stamp = DateFormatter()
                stamp.dateFormat = "yyyyMMdd-HHmmss"
                let name = dest.deletingPathExtension().lastPathComponent + "-" + stamp.string(from: Date()) + ".sav"
                try fm.copyItem(at: dest, to: backups.appendingPathComponent(name))
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: picked, to: dest)
            if isInTemp(picked) { try? fm.removeItem(at: picked) }
            try open(rom: rom)
            status += " (save imported; the previous one is in Saves/Backups)"
        } catch {
            status = "Could not import the save: \(error.localizedDescription)"
            try? open(rom: rom)
        }
    }

    /// Flushes the save and returns a fresh copy in tmp for the "Save to Files" exporter.
    func exportSaveCopy() -> URL? {
        guard let rom = romURL, let core = core else {
            status = "Nothing to export: no ROM is loaded."
            return nil
        }
        core.flushSave()
        let source = saveURL(for: rom)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(source.lastPathComponent)
        do {
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: source, to: copy)
            return copy
        } catch {
            status = "Could not export the save: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Sync hooks (SyncManager)

    var romsDirectory: URL { romsDir }

    /// A game is on screen and running (not just loaded).
    var isPlaying: Bool { link != nil }

    /// The ROM the game screen opens by default.
    func preferROM(named name: String) {
        UserDefaults.standard.set(name, forKey: Emulator.lastROMKey)
    }

    /// The save bytes for a ROM in ROMs/, flushed first if that game is loaded. nil if there is no save yet.
    func saveData(forROMNamed name: String, flush: Bool) -> Data? {
        if flush, romURL?.lastPathComponent == name { core?.flushSave() }
        return try? Data(contentsOf: saveURL(for: romsDir.appendingPathComponent(name)))
    }

    func saveDate(forROMNamed name: String) -> Date? {
        let url = saveURL(for: romsDir.appendingPathComponent(name))
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Lets go of a ROM file so it can be replaced. Refuses (false) while that game is being played.
    func releaseROM(named name: String) -> Bool {
        guard core != nil, romURL?.lastPathComponent == name else { return true }
        if isPlaying { return false }
        closeCore()
        return true
    }

    /// Replaces the save for a ROM in ROMs/ (keeping the old one in Saves/Backups), restarting that game if loaded.
    func replaceSave(forROMNamed name: String, with data: Data, tag: String) throws {
        let rom = romsDir.appendingPathComponent(name)
        let wasOpen = core != nil && romURL?.lastPathComponent == name
        if wasOpen { closeCore() }
        let fm = FileManager.default
        try fm.createDirectory(at: savesDir, withIntermediateDirectories: true)
        let dest = saveURL(for: rom)
        if fm.fileExists(atPath: dest.path) {
            let backups = savesDir.appendingPathComponent("Backups", isDirectory: true)
            try fm.createDirectory(at: backups, withIntermediateDirectories: true)
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            let backupName = dest.deletingPathExtension().lastPathComponent + "-" + tag + "-" + stamp.string(from: Date()) + ".sav"
            try fm.copyItem(at: dest, to: backups.appendingPathComponent(backupName))
            pruneBackups(in: backups, keep: 50)
        }
        try data.write(to: dest, options: .atomic)
        if wasOpen {
            try open(rom: rom)
            status += " (newest save loaded from the NAS)"
        }
    }

    private func pruneBackups(in dir: URL, keep: Int) {
        let fm = FileManager.default
        let items = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "sav" }
        guard items.count > keep else { return }
        // Every name ends in a yyyyMMdd-HHmmss stamp; sort by that so the oldest go first.
        let byStamp = items.sorted { $0.deletingPathExtension().lastPathComponent.suffix(15) < $1.deletingPathExtension().lastPathComponent.suffix(15) }
        for old in byStamp.prefix(items.count - keep) { try? fm.removeItem(at: old) }
    }

    // MARK: - Core lifecycle

    private func open(rom: URL) throws {
        closeCore()
        let fm = FileManager.default
        try fm.createDirectory(at: savesDir, withIntermediateDirectories: true)
        let save = saveURL(for: rom)
        // A .sav dropped next to the ROM (Files app) seeds the save once, if there is none yet.
        let sibling = rom.deletingPathExtension().appendingPathExtension("sav")
        if !fm.fileExists(atPath: save.path), fm.fileExists(atPath: sibling.path) {
            try fm.copyItem(at: sibling, to: save)
        }
        let newCore = try MGBACore(romURL: rom, saveURL: save)
        core = newCore
        romURL = rom
        romName = rom.lastPathComponent
        UserDefaults.standard.set(rom.lastPathComponent, forKey: Emulator.lastROMKey)
        ewramAddressAtOpen = newCore.ewramAddress
        benchText = ""
        resetClock()
        status = "Loaded \(rom.lastPathComponent). mGBA \(MGBACore.versionString). Save: \(newCore.saveTypeName), \(newCore.saveSize) bytes."
        updateRunning()
    }

    private func closeCore() {
        stopLink()
        core = nil // deinit flushes and frees the core
        screen?.clear()
    }

    func reset() {
        guard let core = core else { return }
        core.reset()
        audio.flush()
        resetClock()
        status = "Reset."
    }

    private func resetClock() {
        lastTimestamp = 0
        accumulator = 0
        winStart = 0
        winTicks = 0
        winFrames = 0
        winRunSum = 0
        winRunMax = 0
    }

    // MARK: - Visibility / lifecycle hooks

    /// A game was played before and its ROM is still on the phone, so the app can open straight into it.
    var canResume: Bool {
        guard let name = UserDefaults.standard.string(forKey: Emulator.lastROMKey) else { return false }
        return localROMs().contains { $0.lastPathComponent == name }
    }

    func screenDidAppear() {
        visible = true
        UIApplication.shared.isIdleTimerDisabled = true
        if core == nil, let name = UserDefaults.standard.string(forKey: Emulator.lastROMKey) {
            let candidates = localROMs().filter { $0.lastPathComponent == name }
            if let rom = candidates.first {
                do { try open(rom: rom) } catch { status = "Could not reopen \(name): \(error.localizedDescription)" }
            }
        }
        updateRunning()
    }

    func screenDidDisappear() {
        visible = false
        UIApplication.shared.isIdleTimerDisabled = false
        updateRunning()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            inForeground = true
        case .inactive, .background:
            inForeground = false
            core?.flushSave() // the app may be suspended or killed from here
        @unknown default:
            break
        }
        updateRunning()
    }

    private func updateRunning() {
        if core != nil && visible && inForeground {
            startLink()
        } else {
            stopLink()
        }
    }

    private func startLink() {
        guard link == nil else { return }
        let newLink = CADisplayLink(target: linkTarget, selector: #selector(LinkTarget.fire(_:)))
        newLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        newLink.add(to: .main, forMode: .common)
        link = newLink
        resetClock()
        audio.flush()
        audio.start()
        followOtherAudio()
    }

    private func stopLink() {
        guard let old = link else { return }
        old.invalidate()
        link = nil
        audio.pause()
        core?.setKeys([])
        core?.flushSave()
        fastForward = false
    }

    // MARK: - The clock

    fileprivate func tick(_ link: CADisplayLink) {
        guard let core = core else { return }
        let now = link.timestamp
        var dt = lastTimestamp == 0 ? Emulator.frameDuration : now - lastTimestamp
        lastTimestamp = now
        if dt > 0.1 { dt = 0.1 } // after a stall, do not try to catch up
        let speed = fastForward ? Double(Emulator.fastSpeed) : 1
        accumulator += dt * speed
        winTicks += 1

        let keys = touchKeys.union(padKeys)
        core.setKeys(keys)
        winKeysSent.formUnion(keys)
        winKeysCore.formUnion(core.keys)
        var ran = 0
        let maxFrames = 4 * Int(speed)
        while accumulator >= Emulator.frameDuration && ran < maxFrames {
            let start = CACurrentMediaTime()
            core.runFrame()
            let ms = (CACurrentMediaTime() - start) * 1000.0
            pumpAudio(core, play: !fastForward) // sped-up sound is noise: drain it silently
            winFrames += 1
            winRunSum += ms
            if ms > winRunMax { winRunMax = ms }
            accumulator -= Emulator.frameDuration
            ran += 1
        }
        if ran == maxFrames { accumulator = 0 }
        if ran > 0 {
            screen?.present(pixels: core.pixels)
            overlay.framesDidRun(core)
        }
        updateStats(core, now: now)
    }

    /// Moves everything the core produced this frame into the audio ring (or drops it, during fast forward).
    private func pumpAudio(_ core: MGBACore, play: Bool = true) {
        while true {
            let n = core.readAudio(into: audioScratch, maxFrames: Emulator.scratchFrames)
            if n == 0 { break }
            if play { audio.push(audioScratch, frames: n, rate: core.audioRate) }
        }
    }

    static var fastSpeed: Int {
        let v = UserDefaults.standard.integer(forKey: "ffSpeed")
        return v == 0 ? 3 : max(2, min(4, v))
    }

    func setFastForward(_ on: Bool) {
        guard on != fastForward else { return }
        fastForward = on
        if !on {
            audio.flush()
            accumulator = 0
        }
    }

    private func updateStats(_ core: MGBACore, now: CFTimeInterval) {
        if winStart == 0 { winStart = now }
        let span = now - winStart
        guard span >= 0.5 else { return }
        let emuFps = Double(winFrames) / span
        let displayHz = Double(winTicks) / span
        let avg = winFrames > 0 ? winRunSum / Double(winFrames) : 0
        let audioStatus = audio.status()
        let count = core.readMemory(address: Emulator.partyCountAddress, length: 1)?.first
        let pointerState = core.ewramAddress == ewramAddressAtOpen ? "stable" : "MOVED"
        let pads = GCController.controllers().count
        let countText: String
        if let count = count { countText = String(count) } else { countText = "?" }
        let line1 = "emu \(fmt(emuFps, 1)) fps | display \(fmt(displayHz, 0)) Hz | run \(fmt(avg, 2))/\(fmt(winRunMax, 2)) ms"
        let line2 = "audio \(core.audioRate)>\(fmt(audioStatus.hardwareRate, 0)) Hz | \(fmt(audioStatus.bufferedMs, 0)) ms | \(audioStatus.underruns) underruns"
        let line3 = "save \(core.saveTypeName) \(core.saveSize) B | RAM[0x02036C79]=\(countText) | ptr \(pointerState) | pads \(pads)"
        // Everything pressed during the last half second, so a quick tap still shows up.
        let line4 = "keys sent \(Emulator.keyNames(winKeysSent)) | core got \(Emulator.keyNames(winKeysCore))"
        debugText = [line1, line2, line3, line4].joined(separator: "\n")
        winStart = now
        winTicks = 0
        winFrames = 0
        winRunSum = 0
        winRunMax = 0
        winKeysSent = []
        winKeysCore = []
    }

    static func keyNames(_ keys: GBAKeys) -> String {
        let names: [(GBAKeys, String)] = [(.a, "A"), (.b, "B"), (.select, "Sel"), (.start, "Start"), (.right, "Right"),
                                          (.left, "Left"), (.up, "Up"), (.down, "Down"), (.r, "R"), (.l, "L")]
        let held = names.filter { keys.contains($0.0) }.map(\.1)
        return held.isEmpty ? "-" : held.joined(separator: "+")
    }

    private func fmt(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    // MARK: - Benchmark

    /// Runs 600 frames back to back (no display pacing) and reports throughput. Advances the game by 10 seconds.
    func runBenchmark() {
        guard let core = core else {
            benchText = "benchmark: load a ROM first"
            return
        }
        let wasRunning = link != nil
        stopLink()
        core.setKeys([])
        let frames = 600
        let start = CACurrentMediaTime()
        for _ in 0..<frames {
            core.runFrame()
            while core.readAudio(into: audioScratch, maxFrames: Emulator.scratchFrames) > 0 {} // drain, like the real loop
        }
        let seconds = CACurrentMediaTime() - start
        let fps = Double(frames) / seconds
        benchText = "benchmark: \(frames) frames in \(fmt(seconds, 2)) s = \(fmt(fps, 0)) fps = \(fmt(fps / 59.7275, 1))x real time"
        screen?.present(pixels: core.pixels)
        if wasRunning { updateRunning() }
    }

    // MARK: - Input

    /// Each on-screen pad reports everything it holds; the game gets the union of all pads.
    func setTouchKeys(_ keys: GBAKeys, from source: String) {
        touchSources[source] = keys
        touchKeys = touchSources.values.reduce(into: GBAKeys()) { $0.formUnion($1) }
    }

    private func observeControllers() {
        let center = NotificationCenter.default
        center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            if let controller = note.object as? GCController { self?.attach(controller) }
        }
        center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.padKeys = []
        }
        for controller in GCController.controllers() { attach(controller) }
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        pad.valueChangedHandler = { [weak self] gamepad, _ in
            self?.padKeys = Emulator.keys(from: gamepad)
        }
    }

    /// Positional mapping: GBA A is the right-hand face button, B the bottom one (Xbox B and A respectively).
    /// Nintendo-layout pads may report buttonA/buttonB by label rather than position; swap here if a pad
    /// feels crossed.
    private static func keys(from pad: GCExtendedGamepad) -> GBAKeys {
        var keys: GBAKeys = []
        if pad.buttonB.isPressed || pad.buttonY.isPressed { keys.insert(.a) }
        if pad.buttonA.isPressed || pad.buttonX.isPressed { keys.insert(.b) }
        if pad.leftShoulder.isPressed || pad.leftTrigger.isPressed { keys.insert(.l) }
        if pad.rightShoulder.isPressed || pad.rightTrigger.isPressed { keys.insert(.r) }
        if pad.buttonMenu.isPressed { keys.insert(.start) }
        if pad.buttonOptions?.isPressed == true { keys.insert(.select) }
        let x = pad.leftThumbstick.xAxis.value
        let y = pad.leftThumbstick.yAxis.value
        if pad.dpad.up.isPressed || y > 0.5 { keys.insert(.up) }
        if pad.dpad.down.isPressed || y < -0.5 { keys.insert(.down) }
        if pad.dpad.left.isPressed || x < -0.5 { keys.insert(.left) }
        if pad.dpad.right.isPressed || x > 0.5 { keys.insert(.right) }
        return keys
    }
}

/// CADisplayLink retains its target; this hop keeps the Emulator itself out of that cycle.
private final class LinkTarget: NSObject {
    weak var owner: Emulator?
    @objc func fire(_ link: CADisplayLink) {
        owner?.tick(link)
    }
}
