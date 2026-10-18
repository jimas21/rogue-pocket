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
        VStack(spacing: 10) {
            GameScreen(emulator: emu)
                .aspectRatio(240.0 / 160.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
            infoBlock
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                HStack {
                    HoldButton(label: "L", keys: .l, emulator: emu, width: 96, height: 40, round: false)
                    Spacer()
                    HoldButton(label: "R", keys: .r, emulator: emu, width: 96, height: 40, round: false)
                }
                HStack(alignment: .center) {
                    DPad(emulator: emu)
                    Spacer(minLength: 8)
                    VStack(spacing: 20) {
                        HoldButton(label: "Select", keys: .select, emulator: emu, width: 78, height: 34)
                        HoldButton(label: "Start", keys: .start, emulator: emu, width: 78, height: 34)
                    }
                    Spacer(minLength: 8)
                    abCluster
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var landscape: some View {
        HStack(spacing: 8) {
            VStack(spacing: 14) {
                HoldButton(label: "L", keys: .l, emulator: emu, width: 96, height: 40, round: false)
                DPad(emulator: emu, side: 130)
            }
            VStack(spacing: 6) {
                GameScreen(emulator: emu)
                    .aspectRatio(240.0 / 160.0, contentMode: .fit)
                infoBlock
                HStack(spacing: 16) {
                    HoldButton(label: "Select", keys: .select, emulator: emu, width: 78, height: 30)
                    HoldButton(label: "Start", keys: .start, emulator: emu, width: 78, height: 30)
                }
            }
            VStack(spacing: 14) {
                HoldButton(label: "R", keys: .r, emulator: emu, width: 96, height: 40, round: false)
                abCluster
            }
        }
        .padding(.horizontal, 8)
    }

    private var abCluster: some View {
        ZStack {
            HoldButton(label: "B", keys: .b, emulator: emu).offset(x: -34, y: 24)
            HoldButton(label: "A", keys: .a, emulator: emu).offset(x: 34, y: -24)
        }
        .frame(width: 140, height: 130)
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
