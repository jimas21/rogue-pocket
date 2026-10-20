import SwiftUI

/// The game, full screen (presented as a cover: no back-swipe for a thumb on the D-pad to trigger by accident).
/// Portrait: picture across the full width, the Dex strip, then the controls. Landscape: the biggest picture that
/// still leaves room for a control column on each side INSIDE the safe area, so nothing sits under the Dynamic
/// Island (it is a hole in the screen; touches there never register) or over the picture.
struct EmulatorScreen: View {
    @ObservedObject var emu: Emulator
    @ObservedObject var sync: SyncManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("showDebug") private var showDebug = false
    @AppStorage("ffSpeed") private var ffSpeed = 3
    @State private var sheet: Sheet?
    @State private var showDex = false

    /// Width of each control column in landscape.
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
                if geo.size.width > geo.size.height {
                    landscape(geo.size)
                } else {
                    portrait
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea(edges: .bottom) // the controls may use the home-indicator strip; that swipe is deferred
        .background(Color.black.ignoresSafeArea())
        .sheet(item: $sync.choice) { choice in
            SaveChoiceView(choice: choice, sync: sync)
        }
        .background(fileSheets) // the file sheets hang off their own view (one .sheet per view)
        .background(Color.clear.sheet(isPresented: $showDex) { DexSheet(sync: sync) })
        // Touches near the screen edges go to the controls first, not to the Home/notification swipes.
        .defersSystemGestures(on: .all)
        .persistentSystemOverlays(.hidden)
        .statusBarHidden()
        .onAppear { emu.screenDidAppear() }
        .onDisappear { emu.screenDidDisappear() }
    }

    // MARK: layouts

    private var portrait: some View {
        VStack(spacing: 8) {
            picture
            Button {
                showDex = true
            } label: {
                DexStrip(sync: sync)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            ControllerPad(elements: PadLayout.portrait, layoutID: "portrait", emulator: emu)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.bottom, 6)
    }

    private func landscape(_ size: CGSize) -> some View {
        let pictureWidth = max(240, min(size.width - 2 * Self.sideColumn, size.height * 1.5))
        let side = (size.width - pictureWidth) / 2
        return HStack(spacing: 0) {
            ControllerPad(elements: PadLayout.landscapeLeft, layoutID: "left", emulator: emu)
                .frame(width: side)
            picture
                .frame(width: pictureWidth)
            ControllerPad(elements: PadLayout.landscapeRight, layoutID: "right", emulator: emu)
                .frame(width: side)
        }
    }

    private var picture: some View {
        GameScreen(emulator: emu)
            .aspectRatio(240.0 / 160.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottomLeading) {
                if showDebug {
                    infoBlock
                        .padding(6)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                        .padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                gameMenu.padding(6)
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
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.black.opacity(0.45), in: Circle())
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

/// The strip between the picture and the controls in portrait. The Rogue Dex card goes here; until then it shows
/// what the sync is doing, so a pending save or an offline phone is visible while playing.
private struct DexStrip: View {
    @ObservedObject var sync: SyncManager

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: sync.paired ? "externaldrive.fill.badge.checkmark" : "externaldrive")
                .foregroundStyle(sync.paired ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(sync.statusText)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                if let last = sync.lastSync {
                    Text("Synced \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            Spacer(minLength: 0)
            if sync.syncing {
                ProgressView().tint(.white)
            } else {
                Label("Dex", systemImage: "book.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(Color(red: 0.12, green: 0.15, blue: 0.2), in: RoundedRectangle(cornerRadius: 12))
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
