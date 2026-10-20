import CryptoKit
import Foundation
import Network
import Security
import UIKit

// Keeps the phone's ROM and save in step with the NAS (the rogue-sync service), so the same run carries on across the
// iPhone, the Steam Deck and the Steam Machine (they share the NAS save through Syncthing).
//
// The phone always plays from its own copies, so it works offline. When it can reach the NAS:
//   - ROM: if the NAS has a different ROM, it downloads it (never while that game is on screen).
//   - Save: compares three things: the phone's save, the NAS save, and "base" (the NAS save both last agreed on).
//       only the phone changed  -> upload (the NAS refuses if its save moved meanwhile: then it is a conflict)
//       only the NAS changed    -> download, unless it looks OLDER than base (the Deck wrote back a stale copy) or a
//                                  game is running (then it asks)
//       both changed            -> ask which to keep
//     Nothing is ever replaced without a backup: the phone keeps Saves/Backups, the NAS keeps its own.
//
// Nothing personal is in this file: the NAS addresses and the key arrive by scanning the pairing QR code, and live in
// UserDefaults (addresses) and the Keychain (key).

struct SaveMeta: Codable, Equatable {
    let sha256: String
    let size: Int
    let mtime: Int
    let counter: Int?
}

struct ROMMeta: Codable {
    let sha256: String
    let size: Int
    let mtime: Int
    let name: String
}

private struct RemoteStatus: Codable {
    let rom: ROMMeta
    let save: SaveMeta
}

private struct SaveReply: Codable {
    let save: SaveMeta
}

struct Pairing: Codable {
    let lan: URL
    let wan: URL
}

/// What the phone and the NAS last agreed on.
private struct SyncState: Codable {
    var baseSHA: String?
    var baseCounter: Int?
    var romSHA: String?
    var romName: String?
    var lastSync: Date?
}

/// A decision for the player. Shown as a sheet from anywhere in the app.
struct SaveChoice: Identifiable {
    enum Kind {
        case bothChanged      // phone and another device both saved since the last sync
        case nasOlder         // the NAS save went backwards (a device wrote back an older copy)
        case nasNewerPlaying  // the NAS has a newer save, but a game is running on the phone
        case firstPairing     // the phone already had a save before pairing, and it differs from the NAS
    }

    let id = UUID()
    let kind: Kind
    let nas: SaveMeta
    let phoneCounter: Int?
    let phoneDate: Date?
}

enum SaveFile {
    private static let sector = 0x1000
    private static let slot = 14 * 0x1000
    private static let signature: UInt32 = 0x0801_2025

    /// The game's own save counter: the highest one among valid sectors. It goes up by one on every in-game save.
    static func counter(_ data: Data) -> Int? {
        var best: UInt32?
        data.withUnsafeBytes { raw in
            for s in 0..<2 {
                for i in 0..<14 {
                    let off = s * slot + i * sector
                    guard off + sector <= raw.count else { return }
                    let sig = raw.loadUnaligned(fromByteOffset: off + 0xFF8, as: UInt32.self).littleEndian
                    let ctr = raw.loadUnaligned(fromByteOffset: off + 0xFFC, as: UInt32.self).littleEndian
                    if sig == signature, best == nil || ctr > best! { best = ctr }
                }
            }
        }
        return best.map { Int($0) }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(file url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum Keychain {
    private static let service = "roguepocket.sync"

    static func set(_ value: String, account: String) {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum SyncError: LocalizedError {
    case unreachable
    case notPaired
    case http(Int, String)
    case badData(String)

    var errorDescription: String? {
        switch self {
        case .unreachable: return "Offline. Playing from the phone's copy; it syncs when there's a connection."
        case .notPaired: return "The NAS no longer accepts this phone. Pair again."
        case .http(let code, let text): return "NAS error \(code): \(text)"
        case .badData(let text): return text
        }
    }
}

@MainActor
final class SyncManager: ObservableObject {
    @Published private(set) var paired = false
    @Published private(set) var syncing = false
    @Published private(set) var statusText = "Not paired with the NAS."
    @Published private(set) var lastSync: Date?
    @Published private(set) var progress: Double?
    @Published var choice: SaveChoice?

    private let emulator: Emulator
    private var pairing: Pairing?
    private var state = SyncState()
    private var lastSeenLocalSHA: String?
    private var timer: Timer?
    private let monitor = NWPathMonitor()
    private var online = false
    private var again = false

    private static let pairingKey = "syncPairing"
    private static let stateKey = "syncState"
    private static let tokenAccount = "token"

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    init(emulator: Emulator) {
        self.emulator = emulator
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.pairingKey), let p = try? JSONDecoder().decode(Pairing.self, from: data) {
            pairing = p
        }
        if let data = defaults.data(forKey: Self.stateKey), let s = try? JSONDecoder().decode(SyncState.self, from: data) {
            state = s
        }
        paired = pairing != nil && Keychain.get(account: Self.tokenAccount) != nil
        lastSync = state.lastSync
        if paired { statusText = "Paired with the NAS." }
        if let name = state.romName { emulator.preferROM(named: name) }

        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let now = path.status == .satisfied
                let cameBack = now && !self.online
                self.online = now
                if cameBack { await self.sync("back online") }
            }
        }
        monitor.start(queue: DispatchQueue(label: "rogue-pocket.path"))

        // While a game runs, notice in-game saves and push them (the check flushes the save: cheap, 128 KB).
        timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForInGameSave() }
        }
    }

    // MARK: - Pairing

    /// roguepocket://pair?v=1&lan=http://...&wan=https://...&t=KEY (from the QR code on the NAS's pairing page).
    func handle(url: URL) {
        guard url.scheme == "roguepocket", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let lanText = value("lan"), let lan = URL(string: lanText), lan.scheme == "http" || lan.scheme == "https",
              let wanText = value("wan"), let wan = URL(string: wanText), wan.scheme == "https",
              let token = value("t"), token.count >= 32 else {
            statusText = "That pairing code didn't look right. Open the pairing page again and rescan."
            return
        }
        pairing = Pairing(lan: lan, wan: wan)
        if let data = try? JSONEncoder().encode(pairing) { UserDefaults.standard.set(data, forKey: Self.pairingKey) }
        Keychain.set(token, account: Self.tokenAccount)
        paired = true
        statusText = "Paired. Syncing..."
        Task { await sync("paired") }
    }

    func unpair() {
        pairing = nil
        Keychain.delete(account: Self.tokenAccount)
        UserDefaults.standard.removeObject(forKey: Self.pairingKey)
        paired = false
        statusText = "Not paired with the NAS."
    }

    // MARK: - Triggers

    func appBecameActive() {
        Task { await sync("opened") }
    }

    func appWentToBackground() {
        guard paired else { return }
        let app = UIApplication.shared
        var task: UIBackgroundTaskIdentifier = .invalid
        task = app.beginBackgroundTask(withName: "save sync") {
            app.endBackgroundTask(task)
            task = .invalid
        }
        Task {
            await sync("left the app", allowDownloads: false)
            if task != .invalid { app.endBackgroundTask(task) }
        }
    }

    private func checkForInGameSave() {
        guard paired, online, !syncing, let name = state.romName,
              let data = emulator.saveData(forROMNamed: name, flush: true) else { return }
        let sha = SaveFile.sha256(data.prefix(131_072))
        if lastSeenLocalSHA != nil, sha != lastSeenLocalSHA {
            Task { await sync("saved in game") }
        }
        lastSeenLocalSHA = sha
    }

    // MARK: - Sync

    func sync(_ reason: String, allowDownloads: Bool = true) async {
        guard let pairing, let token = Keychain.get(account: Self.tokenAccount) else { return }
        if syncing {
            again = true
            return
        }
        syncing = true
        defer {
            syncing = false
            progress = nil
            if again {
                again = false
                Task { await sync("queued") }
            }
        }
        do {
            let (base, status) = try await reach(pairing, token: token)
            if allowDownloads { try await syncROM(base, token: token, rom: status.rom) }
            try await syncSave(base, token: token, nas: status.save, allowDownloads: allowDownloads)
            state.lastSync = Date()
            lastSync = state.lastSync
            persist()
        } catch let error as SyncError {
            statusText = error.localizedDescription
        } catch let error as URLError where [.notConnectedToInternet, .timedOut, .cannotConnectToHost,
                                              .networkConnectionLost, .cannotFindHost, .dnsLookupFailed].contains(error.code) {
            statusText = SyncError.unreachable.localizedDescription
        } catch {
            statusText = "Sync failed: \(error.localizedDescription)"
        }
    }

    /// Home Wi-Fi first (fast, 2.5 s), then the internet address.
    private func reach(_ pairing: Pairing, token: String) async throws -> (URL, RemoteStatus) {
        for (base, timeout) in [(pairing.lan, 2.5), (pairing.wan, 20.0)] {
            do {
                let (data, _) = try await request(base, "/v1/status", token: token, timeout: timeout)
                return (base, try JSONDecoder().decode(RemoteStatus.self, from: data))
            } catch SyncError.notPaired {
                throw SyncError.notPaired
            } catch {
                continue
            }
        }
        throw SyncError.unreachable
    }

    private func syncROM(_ base: URL, token: String, rom: ROMMeta) async throws {
        let dest = emulator.romsDirectory.appendingPathComponent(rom.name)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            if state.romSHA == rom.sha256, state.romName == rom.name { return }
            if (try? SaveFile.sha256(file: dest)) == rom.sha256 {
                adoptROM(rom)
                return
            }
        }
        guard emulator.releaseROM(named: rom.name) else {
            statusText = "A new version of the game is waiting. It installs when you leave the game screen."
            return
        }
        statusText = "Downloading the game (\(rom.size / 1_048_576) MB)..."
        var req = URLRequest(url: base.appendingPathComponent("v1/rom"), timeoutInterval: 60)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (tmp, response) = try await session.download(for: req)
        try check(response, data: nil)
        guard try SaveFile.sha256(file: tmp) == rom.sha256 else {
            try? fm.removeItem(at: tmp)
            throw SyncError.badData("The game download was damaged. It will retry next sync.")
        }
        try fm.createDirectory(at: emulator.romsDirectory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmp, to: dest)
        adoptROM(rom)
    }

    private func adoptROM(_ rom: ROMMeta) {
        state.romSHA = rom.sha256
        state.romName = rom.name
        emulator.preferROM(named: rom.name)
        persist()
    }

    private func syncSave(_ base: URL, token: String, nas: SaveMeta, allowDownloads: Bool) async throws {
        guard let name = state.romName else { return }
        guard let local = emulator.saveData(forROMNamed: name, flush: true) else {
            if allowDownloads { try await download(base, token: token, nas: nas, name: name) }
            return
        }
        // mGBA may keep a few bytes of clock data after the save; the NAS (RetroArch) file is the save alone.
        let slice = local.prefix(nas.size)
        let localSHA = SaveFile.sha256(slice)
        lastSeenLocalSHA = localSHA
        if localSHA == nas.sha256 {
            agree(nas)
            statusText = "In sync."
            return
        }
        let phoneCounter = SaveFile.counter(slice)
        let phoneDate = emulator.saveDate(forROMNamed: name)
        guard let baseSHA = state.baseSHA else {
            choice = SaveChoice(kind: .firstPairing, nas: nas, phoneCounter: phoneCounter, phoneDate: phoneDate)
            statusText = "Choose which save to keep."
            return
        }
        let localChanged = localSHA != baseSHA
        let nasChanged = nas.sha256 != baseSHA
        if localChanged && !nasChanged {
            try await upload(base, token: token, data: slice, over: nas, phoneDate: phoneDate)
        } else if nasChanged && !localChanged {
            if let was = state.baseCounter, let now = nas.counter, now < was {
                choice = SaveChoice(kind: .nasOlder, nas: nas, phoneCounter: phoneCounter, phoneDate: phoneDate)
                statusText = "The NAS has an older save. Choose which to keep."
            } else if !allowDownloads {
                statusText = "The NAS has a newer save. It loads next time you open the app."
            } else if emulator.isPlaying {
                choice = SaveChoice(kind: .nasNewerPlaying, nas: nas, phoneCounter: phoneCounter, phoneDate: phoneDate)
                statusText = "The NAS has a newer save."
            } else {
                try await download(base, token: token, nas: nas, name: name)
            }
        } else {
            choice = SaveChoice(kind: .bothChanged, nas: nas, phoneCounter: phoneCounter, phoneDate: phoneDate)
            statusText = "Both saves changed. Choose which to keep."
        }
    }

    private func upload(_ base: URL, token: String, data: Data, over nas: SaveMeta, phoneDate: Date?) async throws {
        statusText = "Uploading the save..."
        do {
            let (reply, _) = try await request(base, "/v1/save", method: "PUT", token: token, body: data,
                                               headers: ["X-Base-SHA256": nas.sha256], timeout: 30)
            let saved = try JSONDecoder().decode(SaveReply.self, from: reply).save
            agree(saved)
            statusText = "Save uploaded. The Steam Deck gets it through Syncthing."
        } catch SyncError.http(409, _) {
            // The NAS save moved since the status call: re-run the whole comparison against it.
            again = true
            statusText = "The NAS save changed meanwhile. Checking again..."
        }
    }

    private func download(_ base: URL, token: String, nas: SaveMeta, name: String) async throws {
        statusText = "Downloading the save..."
        let (data, _) = try await request(base, "/v1/save", token: token, timeout: 30)
        guard SaveFile.sha256(data) == nas.sha256 else {
            throw SyncError.badData("The NAS save changed during the download. It will retry next sync.")
        }
        try emulator.replaceSave(forROMNamed: name, with: data, tag: "before-nas")
        agree(nas)
        lastSeenLocalSHA = nas.sha256
        statusText = "Loaded the newest save from the NAS."
    }

    private func agree(_ meta: SaveMeta) {
        state.baseSHA = meta.sha256
        state.baseCounter = meta.counter
        persist()
    }

    // MARK: - Choices

    func keepPhone(_ choice: SaveChoice) {
        self.choice = nil
        Task {
            guard let pairing, let token = Keychain.get(account: Self.tokenAccount), let name = state.romName,
                  let local = emulator.saveData(forROMNamed: name, flush: true) else { return }
            do {
                let (base, _) = try await reach(pairing, token: token)
                try await upload(base, token: token, data: local.prefix(choice.nas.size), over: choice.nas,
                                 phoneDate: choice.phoneDate)
            } catch {
                statusText = (error as? SyncError)?.localizedDescription ?? "Upload failed: \(error.localizedDescription)"
            }
            if again {
                again = false
                await sync("after choice")
            }
        }
    }

    func useNAS(_ choice: SaveChoice) {
        self.choice = nil
        Task {
            guard let pairing, let token = Keychain.get(account: Self.tokenAccount), let name = state.romName else { return }
            do {
                let (base, _) = try await reach(pairing, token: token)
                try await download(base, token: token, nas: choice.nas, name: name)
            } catch {
                statusText = (error as? SyncError)?.localizedDescription ?? "Download failed: \(error.localizedDescription)"
            }
        }
    }

    func decideLater() {
        choice = nil
        statusText = "Not synced: the saves differ. You'll be asked again next sync."
    }

    // MARK: - Plumbing

    private func persist() {
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: Self.stateKey) }
    }

    private func request(_ base: URL, _ path: String, method: String = "GET", token: String, body: Data? = nil,
                         headers: [String: String] = [:], timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: base.appendingPathComponent(String(path.dropFirst())), timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body {
            req.httpBody = body
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        let http = try check(response, data: data)
        return (data, http)
    }

    @discardableResult
    private func check(_ response: URLResponse, data: Data?) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw SyncError.unreachable }
        switch http.statusCode {
        case 200..<300: return http
        case 401: throw SyncError.notPaired
        default:
            var text = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = obj["error"] as? String { text = error }
            throw SyncError.http(http.statusCode, text)
        }
    }
}
