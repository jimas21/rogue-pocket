import CryptoKit
import Foundation

/// The phone's own copy of the Rogue Dex (the web page and its data), plus the Dex's saved state. Kept in
/// Application Support so it works with no connection; refreshed from the NAS whenever a sync reaches it.
final class DexStore {
    static let shared = DexStore()

    let root: URL
    private let filesDir: URL
    private let manifestURL: URL
    private let stateURL: URL
    private let lock = NSLock()

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("RogueDex", isDirectory: true)
        filesDir = root.appendingPathComponent("www", isDirectory: true)
        manifestURL = root.appendingPathComponent("manifest.json")
        stateURL = root.appendingPathComponent("state.json")
        try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
    }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: filesDir.appendingPathComponent("index.html").path) }

    /// A file of the Dex page, or nil for anything outside it.
    func file(at path: String) -> Data? {
        let clean = path.split(separator: "/").filter { !$0.isEmpty && $0 != "." }
        guard !clean.contains(where: { $0 == ".." }) else { return nil }
        let url = clean.reduce(filesDir) { $0.appendingPathComponent(String($1)) }
        guard url.standardizedFileURL.path.hasPrefix(filesDir.standardizedFileURL.path + "/") else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - Files

    private struct Manifest: Codable {
        struct Entry: Codable, Equatable {
            let sha256: String
            let size: Int
        }

        let files: [String: Entry]
    }

    private func localManifest() -> Manifest {
        guard let data = try? Data(contentsOf: manifestURL),
              let m = try? JSONDecoder().decode(Manifest.self, from: data) else { return Manifest(files: [:]) }
        return m
    }

    /// Brings the local copy up to date with the NAS manifest: downloads changed files, removes deleted ones.
    /// `fetch(path)` returns the file's bytes from the NAS.
    @MainActor
    func update(remoteManifest data: Data, fetch: (String) async throws -> Data,
                progress: (Int, Int) -> Void) async throws -> Int {
        let remote = try JSONDecoder().decode(Manifest.self, from: data)
        var local = localManifest()
        let fm = FileManager.default
        let changed = remote.files.filter { path, entry in
            local.files[path] != entry || !fm.fileExists(atPath: filesDir.appendingPathComponent(path).path)
        }.keys.sorted()
        var done = 0
        for path in changed {
            guard let entry = remote.files[path] else { continue }
            let bytes = try await fetch(path)
            guard bytes.count == entry.size, SaveFile.sha256(bytes) == entry.sha256 else {
                throw SyncError.badData("A Dex file arrived damaged. It will retry next sync.")
            }
            let dest = filesDir.appendingPathComponent(path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: dest, options: .atomic)
            var files = local.files
            files[path] = entry
            local = Manifest(files: files)
            done += 1
            if done % 50 == 0 {
                saveManifest(local) // a cut-off sync resumes where it stopped
            }
            progress(done, changed.count)
        }
        for path in local.files.keys where remote.files[path] == nil {
            try? fm.removeItem(at: filesDir.appendingPathComponent(path))
        }
        saveManifest(remote)
        return changed.count
    }

    private func saveManifest(_ m: Manifest) {
        if let data = try? JSONEncoder().encode(m) { try? data.write(to: manifestURL, options: .atomic) }
    }

    // MARK: - State (what the Dex page saves: party picks, prefs, recent opponents)

    /// The state blob, or {} when there is none yet.
    func stateData() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return (try? Data(contentsOf: stateURL)) ?? Data("{}".utf8)
    }

    static func updatedAt(_ data: Data) -> Double {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        return (obj["updatedAt"] as? NSNumber)?.doubleValue ?? 0
    }

    /// The page's PUT /state, with the same rule as the NAS service: the newer updatedAt wins.
    /// Returns the reply body ({ok, applied, state}).
    func putState(_ body: Data) -> (Int, Data) {
        guard body.count <= 256 * 1024 else { return (413, Data(#"{"error":"body too large"}"#.utf8)) }
        guard let incoming = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return (400, Data(#"{"error":"state must be a JSON object"}"#.utf8))
        }
        lock.lock()
        defer { lock.unlock() }
        let current = (try? Data(contentsOf: stateURL)) ?? Data("{}".utf8)
        let currentObj = (try? JSONSerialization.jsonObject(with: current) as? [String: Any]) ?? [:]
        let applied = DexStore.updatedAt(body) >= DexStore.updatedAt(current)
        if applied { try? body.write(to: stateURL, options: .atomic) }
        let reply: [String: Any] = ["ok": true, "applied": applied, "state": applied ? incoming : currentObj]
        return (200, (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8))
    }

    /// Replaces the local state with the NAS copy when that one is newer.
    func adoptIfNewer(_ remote: Data) -> Bool {
        guard (try? JSONSerialization.jsonObject(with: remote)) is [String: Any] else { return false }
        lock.lock()
        defer { lock.unlock() }
        let current = (try? Data(contentsOf: stateURL)) ?? Data("{}".utf8)
        guard DexStore.updatedAt(remote) > DexStore.updatedAt(current) else { return false }
        try? remote.write(to: stateURL, options: .atomic)
        return true
    }
}
