import SwiftUI

/// Root of the app. Spike 001's "Pipeline OK" screen (PipelineView) stays the home screen; the emulator test
/// is one tap away. The Emulator object lives here so a loaded game survives going back and forth.
struct ContentView: View {
    @StateObject private var emulator = Emulator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            PipelineView(emulator: emulator)
        }
        .onChange(of: scenePhase) { _, phase in
            emulator.scenePhaseChanged(phase)
        }
    }
}

#Preview {
    ContentView()
}
