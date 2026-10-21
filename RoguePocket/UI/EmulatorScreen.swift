import SwiftUI

/// The game, full screen (presented as a cover: no back-swipe for a thumb on the D-pad to trigger by accident).
/// Portrait: picture across the full width, the Dex strip, then the controls. Landscape: a control column on each side
/// inside the safe area and the biggest picture between them. Controls move off the Dynamic Island (it is a hole in
/// the screen; touches there never register) and never sit over the picture.
struct EmulatorScreen: View {
    @ObservedObject var emu: Emulator
    @ObservedObject var sync: SyncManager
    @ObservedObject var dex: DexHost
    @Environment(\.dismiss) private var dismiss
    @AppStorage("showDebug") private var showDebug = false
    @AppStorage("ffSpeed") private var ffSpeed = 3
    @AppStorage("colorCorrection") private var colorCorrection = true
    @State private var sheet: Sheet?
    @State private var showDex = false
    /// What the foe has shown this battle, for the strip (portrait only).
    @StateObject private var memory = BattleMemory()
    /// Bumped when the phone turns, so the island side is read again (a half turn keeps the same size).
    @State private var orientationTick = 0

    /// Narrowest control column in landscape (wide screens, iPad).
    private static let sideColumn: CGFloat = 128

    enum Sheet: Identifiable {
        case rom
        case save
        case export(URL)
        case log

        var id: String {
            switch self {
            case .rom: return "rom"
            case .save: return "save"
            case .export(let url): return "export-" + url.path
            case .log: return "log"
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            Group {
                let insets = Self.safeInsets(geo)
                if geo.size.width > geo.size.height {
                    landscape(geo.size, inset: max(insets.leading, insets.trailing))
                } else {
                    portrait.padding(.top, insets.top)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // The whole screen: the controls may use the home-indicator strip (that swipe is deferred) and, in
        // landscape, the side strips beside the island.
        .ignoresSafeArea()
        .background(Color(red: 15 / 255, green: 23 / 255, blue: 20 / 255).ignoresSafeArea())
        .sheet(item: $sync.choice) { choice in
            SaveChoiceView(choice: choice, sync: sync)
        }
        .background(fileSheets) // the file sheets hang off their own view (one .sheet per view)
        .background(Color.clear.sheet(isPresented: $showDex) { DexSheet(sync: sync) })
        // Touches near the screen edges go to the controls first, not to the Home/notification swipes.
        .defersSystemGestures(on: .all)
        .persistentSystemOverlays(.hidden)
        .statusBarHidden()
        .task {
            while !Task.isCancelled {
                await MainActor.run {
                    memory.refresh(from: dex.battleSnapshot(), data: emu.overlay.data)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { orientationTick += 1 }
        }
        .onAppear { emu.screenDidAppear() }
        .onDisappear { emu.screenDidDisappear() }
    }

    // MARK: layouts

    private var portrait: some View {
        VStack(spacing: 8) {
            picture
            HStack(spacing: 8) {
                Button {
                    showDex = true
                } label: {
                    DexStrip(memory: memory, overlay: emu.overlay)
                }
                .buttonStyle(.plain)
                gameMenu
            }
            .padding(.horizontal, 10)
            ControllerPad(elements: PadLayout.portrait, layoutID: "portrait", emulator: emu)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.bottom, 6)
    }

    private func landscape(_ size: CGSize, inset: CGFloat) -> some View {
        // Controls stay inside the safe area (an edge margin as wide as the inset), closer to the picture: at the
        // screen edges they felt too far out. The picture takes what is left, up to full height.
        let margin = inset
        let pictureWidth = max(240, min(size.width - 2 * (margin + Self.sideColumn), size.height * 1.5))
        let side = (size.width - pictureWidth) / 2
        let pad = side - margin
        let island = islandArea(height: size.height, inset: inset)
        // The island rect in each pad's own coordinates (pads start `margin` in from the screen edge).
        let leftAvoid = island.onLeft ? island.rect.offsetBy(dx: -margin, dy: 0) : .null
        let rightAvoid = island.onLeft ? .null : island.rect.offsetBy(dx: pad + margin - island.rect.width, dy: 0)
        return HStack(spacing: 0) {
            ControllerPad(elements: PadLayout.landscapeLeft, layoutID: "left", emulator: emu, avoid: leftAvoid)
                .frame(width: pad)
                .overlay(alignment: .top) {
                    // Low in the column, under Select (see PadLayout.landscapeLeft).
                    gameMenu.padding(.top, size.height * 0.76 - 22)
                }
                .padding(.leading, margin)
            picture
                .frame(width: pictureWidth)
            ControllerPad(elements: PadLayout.landscapeRight, layoutID: "right", emulator: emu, avoid: rightAvoid)
                .frame(width: pad)
                .padding(.trailing, margin)
        }
    }

    /// The screen's safe-area insets: the reader's own, or the window's if the reader reports none.
    private static func safeInsets(_ geo: GeometryProxy) -> EdgeInsets {
        var e = geo.safeAreaInsets
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow
        if let w = window?.safeAreaInsets {
            e.top = max(e.top, w.top)
            e.leading = max(e.leading, w.left)
            e.trailing = max(e.trailing, w.right)
        }
        return e
    }

    /// Where the Dynamic Island (or notch) sits in landscape, in a control column's coordinates, and on which side.
    /// Only the strip beside it, centred on the height, is dead; above and below it touches work.
    private func islandArea(height: CGFloat, inset: CGFloat) -> (rect: CGRect, onLeft: Bool) {
        _ = orientationTick
        guard inset > 30 else { return (.null, true) } // iPad, or no cutout
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        // landscapeRight = the top of the phone (the island) is on the left.
        let onLeft = scene?.interfaceOrientation != .landscapeLeft
        let half: CGFloat = inset >= 55 ? 66 : 112 // island ~126 pt tall; a notch ~210
        let width = inset - 8
        return (CGRect(x: 0, y: height / 2 - half, width: width, height: half * 2), onLeft)
    }

    private var picture: some View {
        GameScreen(emulator: emu, colorCorrection: colorCorrection)
            .aspectRatio(240.0 / 160.0, contentMode: .fit)
            .overlay { BattleOverlayView(overlay: emu.overlay) }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottomLeading) {
                if showDebug {
                    infoBlock
                        .padding(6)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                        .padding(4)
                }
            }
            .overlay(alignment: .topLeading) {
                if emu.fastForward {
                    Text("\u{25B6}\u{25B6} \(ffSpeed)x")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.green.opacity(0.75), in: Capsule())
                        .padding(8)
                }
            }
    }

    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(emu.debugText.isEmpty ? "(debug line appears once a game runs)" : emu.debugText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
            if !emu.benchText.isEmpty {
                Text(emu.benchText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.yellow)
            }
            Text(emu.status)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.75))
            OverlayDebugLine(overlay: emu.overlay)
        }
    }

    private var gameMenu: some View {
        Menu {
            Button {
                dismiss()
            } label: {
                Label("Home", systemImage: "house")
            }
            Button {
                showDex = true
            } label: {
                Label("Rogue Dex", systemImage: "book.fill")
            }
            Button {
                Task { await sync.sync("menu") }
            } label: {
                Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
            }
            Toggle(isOn: $emu.muted) { Label("Mute", systemImage: "speaker.slash") }
            Toggle(isOn: $colorCorrection) { Label("GBA screen colours", systemImage: "paintpalette") }
            Picker(selection: $ffSpeed) {
                Text("2x").tag(2)
                Text("3x").tag(3)
                Text("4x").tag(4)
            } label: {
                Label("Fast forward speed", systemImage: "forward.fill")
            }
            .pickerStyle(.menu)
            Divider()
            Button("Reset game") { emu.reset() }
            Menu("Files") {
                Button("Load ROM...") { sheet = .rom }
                ForEach(emu.localROMs(), id: \.self) { url in
                    Button("Open \(url.lastPathComponent)") { emu.openLocal(url) }
                }
                Divider()
                Button("Import save...") { sheet = .save }
                Button("Export save...") {
                    if let url = emu.exportSaveCopy() { sheet = .export(url) }
                }
            }
            Menu("Debug") {
                Toggle("Show debug info", isOn: $showDebug)
                Button("Benchmark (advances the game 10 s)") { emu.runBenchmark() }
                Button("mGBA log and help") { sheet = .log }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color(red: 191 / 255, green: 245 / 255, blue: 215 / 255))
                .frame(width: 44, height: 44)
                .background(Color(red: 22 / 255, green: 33 / 255, blue: 29 / 255), in: Circle())
                .overlay(Circle().strokeBorder(Color(red: 64 / 255, green: 214 / 255, blue: 140 / 255).opacity(0.5), lineWidth: 1.5))
        }
    }

    private var fileSheets: some View {
        Color.clear.sheet(item: $sheet) { item in
            switch item {
            case .rom:
                OpenFilePicker(
                    onPick: { url in
                        emu.loadROM(from: url)
                        DispatchQueue.main.async { sheet = nil }
                    },
                    onCancel: { sheet = nil }
                ).ignoresSafeArea()
            case .save:
                OpenFilePicker(
                    onPick: { url in
                        emu.importSave(from: url)
                        DispatchQueue.main.async { sheet = nil }
                    },
                    onCancel: { sheet = nil }
                ).ignoresSafeArea()
            case .export(let url):
                ExportFilePicker(url: url, onDone: { sheet = nil }).ignoresSafeArea()
            case .log:
                LogView(emu: emu)
            }
        }
    }
}

/// The strip between the picture and the controls in portrait. In a battle it remembers what the foe has shown
/// (BattleMemoryView); otherwise it is the Dex button. Its height never changes, so the controls never move.
private struct DexStrip: View {
    @ObservedObject var memory: BattleMemory
    @ObservedObject var overlay: BattleOverlay

    var body: some View {
        Group {
            if let facts = memory.facts {
                BattleMemoryView(facts: facts, overlay: overlay)
            } else {
                HStack {
                    Label("Rogue Dex", systemImage: "book.fill")
                        .font(.footnote.bold())
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64, alignment: .leading)
        .background(Color(red: 22 / 255, green: 33 / 255, blue: 29 / 255), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// What mGBA reported (warnings and errors only), plus where files go. Selectable so it can be copied out.
private struct LogView: View {
    @ObservedObject var emu: Emulator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("mGBA log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var text: String {
        let log = emu.core?.logText ?? ""
        return """
        mGBA \(MGBACore.versionString)
        status: \(emu.status)

        mGBA warnings/errors:
        \(log.isEmpty ? "(none)" : log)

        Files: the Files app, On My iPhone, Rogue Pocket. Drop a .gba there (or use the menu, Load ROM). The save
        lives in Saves/<rom name>.sav; a .sav next to the ROM seeds it the first time. The menu entry Export save writes a
        copy out. Importing a save keeps the old one in Saves/Backups.
        """
    }
}

/// The battle overlay's own readout in the debug block: what it sees at each step.
private struct OverlayDebugLine: View {
    @ObservedObject var overlay: BattleOverlay

    var body: some View {
        Text(overlay.debugLine)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.green.opacity(0.9))
            .textSelection(.enabled)
    }
}
