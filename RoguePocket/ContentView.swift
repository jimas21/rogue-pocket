import SwiftUI

/// Root of the app. It opens straight into the last game; the home screen (PipelineView, the game menu's Home) has
/// Play and the NAS sync box. The Emulator object lives here so
/// a loaded game survives going back and forth; SyncManager keeps its ROM and save in step with the NAS.
struct ContentView: View {
    @StateObject private var emulator: Emulator
    @StateObject private var sync: SyncManager
    @StateObject private var dex: DexHost
    @Environment(\.scenePhase) private var scenePhase
    @State private var playing = false

    init() {
        let emu = Emulator()
        _emulator = StateObject(wrappedValue: emu)
        _sync = StateObject(wrappedValue: SyncManager(emulator: emu))
        _dex = StateObject(wrappedValue: DexHost(emulator: emu))
    }

    var body: some View {
        NavigationStack {
            PipelineView(emulator: emulator, sync: sync, play: { playing = true })
        }
        .onOpenURL { url in
            sync.handle(url: url)
        }
        .onChange(of: scenePhase) { _, phase in
            emulator.scenePhaseChanged(phase) // flushes the save first
            switch phase {
            case .active:
                dex.stateChanged = { [weak sync] in sync?.dexStateChanged() }
                dex.start()
                sync.appBecameActive()
            case .background: sync.appWentToBackground()
            default: break
            }
        }
        .fullScreenCover(isPresented: $playing) {
            EmulatorScreen(emu: emulator, sync: sync, dex: dex)
        }
        // While the game is up, EmulatorScreen shows the save prompt itself (a cover hides sheets from below).
        .sheet(item: playing ? .constant(nil) : $sync.choice) { choice in
            SaveChoiceView(choice: choice, sync: sync)
        }
        .task { await openGameAfterFirstSync() }
    }

    /// Straight into the game at launch, once the opening sync has brought the save up to date (or after a few seconds
    /// with no NAS). A save question from that sync keeps the home screen up so it can be answered first.
    @MainActor
    private func openGameAfterFirstSync() async {
        try? await Task.sleep(nanoseconds: 700_000_000) // let the opening sync start
        let deadline = Date().addingTimeInterval(8)
        while sync.syncing && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard !playing, sync.choice == nil, emulator.canResume else { return }
        playing = true
    }
}
