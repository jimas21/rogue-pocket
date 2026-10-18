import SwiftUI

/// Spike 001's "Pipeline OK" screen, kept as the home screen, with a door to the emulator test.
struct PipelineView: View {
    @ObservedObject var emulator: Emulator

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Rogue Pocket")
                .font(.largeTitle.bold())
            Text("Pipeline OK")
                .font(.title2)
                .foregroundStyle(.green)
            Text("Version \(version) (build \(build))")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)

            NavigationLink {
                EmulatorScreen(emu: emulator)
            } label: {
                Label("Emulator test (spike 002)", systemImage: "gamecontroller")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 28)

            Text("Emulation by mGBA \(MGBACore.versionString), MPL-2.0 (mgba.io). Corresponding source: github.com/mgba-emu/mgba, the commit in ci/build_mgba.sh, plus the two CMake lines in ci/mgba_patch.py. No game is included in this app.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 20)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }
}
