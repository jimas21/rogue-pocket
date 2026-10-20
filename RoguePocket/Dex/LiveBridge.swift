import Foundation
import JavaScriptCore

/// Answers the Dex's live endpoints (/party, /battle, /run, /bag) from the running game. The decoding lives in live.js
/// (the same rules as the NAS service that reads RetroArch), run in JavaScriptCore with a memory reader backed by the
/// emulator. Main thread only: mGBA is.
final class LiveBridge {
    private let emulator: Emulator
    private let context: JSContext
    private let live: JSValue

    init?(emulator: Emulator) {
        guard let url = Bundle.main.url(forResource: "live", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext() else { return nil }
        context.exceptionHandler = { _, exception in
            NSLog("RoguePocket live.js: \(exception?.toString() ?? "?")")
        }
        context.evaluateScript(source)
        guard let live = context.objectForKeyedSubscript("RogueLive"), live.isObject else { return nil }
        self.emulator = emulator
        self.context = context
        self.live = live
    }

    /// Handles one live path. Returns (status, JSON body).
    func answer(path: String, query: [String: String]) -> (Int, Data) {
        guard let core = emulator.core else {
            return json(404, ["error": "No game is running in Rogue Pocket. Open Play first."])
        }
        let name: String
        switch path {
        case "/party": name = "party"
        case "/battle": name = "battle"
        case "/run": name = "run"
        case "/bag": name = "bag"
        default: return json(404, ["error": "unknown path"])
        }
        let reader: @convention(block) (Int, Int) -> JSValue = { [weak self] addr, size in
            guard let self, size > 0, size <= 0x40000,
                  let bytes = core.readMemory(address: UInt32(truncatingIfNeeded: addr), length: size) else {
                return JSValue(nullIn: self?.context)
            }
            return self.typedArray(bytes)
        }
        let rom = emulator.romName ?? "?"
        let status = "PLAYING game_boy_advance,\(rom),crc32=rogue-pocket"
        let device: [String: Any] = ["ip": "iphone", "name": "iPhone", "status": status]
        let stamp = DateFormatter()
        stamp.dateFormat = "HH:mm:ss"
        let ctx: [String: Any] = [
            "device": "iphone", "name": "iPhone", "status": status, "devices": [device],
            "readAt": stamp.string(from: Date()), "nowMs": Int(Date().timeIntervalSince1970 * 1000),
        ]
        var args: [Any] = [unsafeBitCast(reader, to: AnyObject.self), ctx]
        if name == "battle" { args.append(query["debug"] == "1") }
        guard let result = live.invokeMethod(name, withArguments: args),
              let code = result.atIndex(0)?.toInt32(),
              let body = result.atIndex(1),
              let text = context.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [body])?.toString()
        else {
            return json(500, ["error": "the live reader failed"])
        }
        return (Int(code), Data(text.utf8))
    }

    private func typedArray(_ bytes: [UInt8]) -> JSValue {
        let count = bytes.count
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 1)
        bytes.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: count) }
        var exception: JSValueRef?
        let ref = JSObjectMakeTypedArrayWithBytesNoCopy(
            context.jsGlobalContextRef, kJSTypedArrayTypeUint8Array, buffer, count,
            { bytes, _ in bytes?.deallocate() }, nil, &exception)
        guard let ref, exception == nil else {
            buffer.deallocate()
            return JSValue(nullIn: context)
        }
        return JSValue(jsValueRef: ref, in: context)
    }

    private func json(_ code: Int, _ obj: [String: Any]) -> (Int, Data) {
        (code, (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8))
    }
}
