import Foundation

/// GBA button bits, same order as mGBA's `enum GBAKey` (and `RP_KEY_*` in rp_core.h).
struct GBAKeys: OptionSet {
    let rawValue: UInt32
    static let a      = GBAKeys(rawValue: 1 << 0)
    static let b      = GBAKeys(rawValue: 1 << 1)
    static let select = GBAKeys(rawValue: 1 << 2)
    static let start  = GBAKeys(rawValue: 1 << 3)
    static let right  = GBAKeys(rawValue: 1 << 4)
    static let left   = GBAKeys(rawValue: 1 << 5)
    static let up     = GBAKeys(rawValue: 1 << 6)
    static let down   = GBAKeys(rawValue: 1 << 7)
    static let r      = GBAKeys(rawValue: 1 << 8)
    static let l      = GBAKeys(rawValue: 1 << 9)
}

enum CoreError: LocalizedError {
    case openFailed(String)
    var errorDescription: String? {
        switch self {
        case .openFailed(let message): return message
        }
    }
}

/// Swift face of the C shim (rp_core.c): one instance per loaded ROM. Main thread only.
///
/// Public surface:
///   init(romURL:saveURL:)  load the ROM and attach the battery save (both before the first reset)
///   runFrame()             advance one frame (about 16.74 ms of GBA time)
///   pixels                 240x160 frame, bytes R,G,B,X
///   readMemory(...)        copy bytes out of EWRAM / IWRAM (the party and battle reads use this)
///   flushSave()            force the memory-mapped save to disk
final class MGBACore {
    static let width = 240
    static let height = 160
    static let ewramBase: UInt32 = 0x0200_0000
    static let ewramSize = 0x4_0000
    static let iwramBase: UInt32 = 0x0300_0000
    static let iwramSize = 0x8000

    private let handle: OpaquePointer

    static var versionString: String { String(cString: rp_mgba_version()) }

    init(romURL: URL, saveURL: URL?) throws {
        var err = [CChar](repeating: 0, count: 256)
        let errLen = err.count
        let opened: OpaquePointer? = romURL.path.withCString { rom in
            if let saveURL = saveURL {
                return saveURL.path.withCString { sav in rp_open(rom, sav, &err, errLen) }
            }
            return rp_open(rom, nil, &err, errLen)
        }
        guard let opened = opened else {
            let log = String(cString: rp_log_text())
            throw CoreError.openFailed(String(cString: err) + (log.isEmpty ? "" : "\n" + log))
        }
        handle = opened
    }

    deinit {
        rp_close(handle) // flushes the save first
    }

    func reset() { rp_reset(handle) }
    func runFrame() { rp_run_frame(handle) }
    var frameCounter: UInt32 { rp_frame_counter(handle) }
    func setKeys(_ keys: GBAKeys) { rp_set_keys(handle, keys.rawValue) }
    var keys: GBAKeys { GBAKeys(rawValue: rp_get_keys(handle)) }

    /// 240 * 160 pixels, 4 bytes each, memory order R,G,B,X. Valid while this object lives.
    var pixels: UnsafePointer<UInt32> { rp_pixels(handle) }

    // MARK: audio
    var audioRate: Int { Int(rp_audio_rate(handle)) }
    /// Copies up to `maxFrames` interleaved stereo frames; returns the number of frames copied.
    func readAudio(into buffer: UnsafeMutablePointer<Int16>, maxFrames: Int) -> Int {
        Int(rp_audio_read(handle, buffer, maxFrames))
    }

    // MARK: save
    func flushSave() { rp_flush_save(handle) }
    var saveTypeName: String { String(cString: rp_save_type_name(handle)) }
    var saveSize: Int { Int(rp_save_size(handle)) }

    // MARK: memory

    /// Host address of EWRAM, as a number, to check that the pointer does not move across reset().
    var ewramAddress: UInt { UInt(bitPattern: rp_memory_ptr(handle, 0, nil)) }

    /// Copies `length` bytes of emulated RAM at GBA address `address` (EWRAM 0x02000000..0x0203FFFF or
    /// IWRAM 0x03000000..0x03007FFF, whole range inside one region). Returns nil when out of range.
    func readMemory(address: UInt32, length: Int) -> [UInt8]? {
        guard length > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: length)
        let copied = out.withUnsafeMutableBufferPointer { rp_read_memory(handle, address, $0.baseAddress, length) }
        return Int(copied) == length ? out : nil
    }

    /// Same, into a caller-owned buffer (no allocation; for per-frame reads).
    @discardableResult
    func readMemory(address: UInt32, into buffer: UnsafeMutableRawBufferPointer) -> Bool {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return false }
        let copied = rp_read_memory(handle, address, base.assumingMemoryBound(to: UInt8.self), buffer.count)
        return Int(copied) == buffer.count
    }

    var logText: String { String(cString: rp_log_text()) }
}
