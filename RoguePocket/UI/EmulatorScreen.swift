import SwiftUI

/// The spike's test screen: game picture, debug numbers, touch controls, and a File menu.
struct EmulatorScreen: View {
    @ObservedObject var emu: Emulator
    @State private var sheet: Sheet?

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
                    landscape
                } else {
                    portrait
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Emulator")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { fileMenu }
        }
        // Touches near the screen edges go to the controls first, not to the Home/notification swipes.
        .defersSystemGestures(on: .all)
        .persistentSystemOverlays(.hidden)
        .onAppear { emu.screenDidAppear() }
        .onDisappear { emu.screenDidDisappear() }
        .sheet(item: $sheet) { item in
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

    // MARK: layouts

    private var portrait: some View {
        VStack(spacing: 8) {
            GameScreen(emulator: emu)
                .aspectRatio(240.0 / 160.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
            infoBlock
                .padding(.horizontal, 12)
            ControllerPad(elements: PadLayout.portrait, layoutID: "portrait", emulator: emu)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.bottom, 4)
    }

    private var landscape: some View {
        HStack(spacing: 0) {
            ControllerPad(elements: PadLayout.landscapeLeft, layoutID: "left", emulator: emu)
                .frame(minWidth: 150, maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 4) {
                GameScreen(emulator: emu)
                    .aspectRatio(240.0 / 160.0, contentMode: .fit)
                infoBlock
            }
            .layoutPriority(1)
            ControllerPad(elements: PadLayout.landscapeRight, layoutID: "right", emulator: emu)
                .frame(minWidth: 150, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(emu.debugText.isEmpty ? "(debug line appears once a game runs)" : emu.debugText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
            if !emu.benchText.isEmpty {
                Text(emu.benchText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.yellow)
            }
            Text(emu.status)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fileMenu: some View {
        Menu {
            Button("Load ROM...") { sheet = .rom }
            ForEach(emu.localROMs(), id: \.self) { url in
                Button("Open \(url.lastPathComponent)") { emu.openLocal(url) }
            }
            Divider()
            Button("Import save...") { sheet = .save }
            Button("Export save...") {
                if let url = emu.exportSaveCopy() { sheet = .export(url) }
            }
            Divider()
            Button("Reset game") { emu.reset() }
            Button("Benchmark (advances the game 10 s)") { emu.runBenchmark() }
            Toggle("Mute", isOn: $emu.muted)
            Button("mGBA log and help") { sheet = .log }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
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
