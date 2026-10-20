import SwiftUI

/// Root of the app. The home screen (PipelineView) has Play and the NAS sync box. The Emulator object lives here so
/// a loaded game survives going back and forth; SyncManager keeps its ROM and save in step with the NAS.
struct ContentView: View {
    @StateObject private var emulator: Emulator
    @StateObject private var sync: SyncManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var playing = false

    init() {
        let emu = Emulator()
        _emulator = StateObject(wrappedValue: emu)
        _sync = StateObject(wrappedValue: SyncManager(emulator: emu))
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
            case .active: sync.appBecameActive()
            case .background: sync.appWentToBackground()
            default: break
            }
        }
        .fullScreenCover(isPresented: $playing) {
            EmulatorScreen(emu: emulator, sync: sync)
        }
        // While the game is up, EmulatorScreen shows the save prompt itself (a cover hides sheets from below).
        .sheet(item: playing ? .constant(nil) : $sync.choice) { choice in
            SaveChoiceView(choice: choice, sync: sync)
        }
    }
}
