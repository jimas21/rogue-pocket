import SwiftUI

/// The home screen: Play, the NAS sync box, and the version.
struct PipelineView: View {
    @ObservedObject var emulator: Emulator
    @ObservedObject var sync: SyncManager
    let play: () -> Void
    @State private var showDex = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Rogue Pocket")
                    .font(.largeTitle.bold())
                    .padding(.top, 24)

                Button {
                    // The Dex panel is a sheet: close it first, or the game can't open over it.
                    if showDex {
                        showDex = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { play() }
                    } else {
                        play()
                    }
                } label: {
                    Label("Play", systemImage: "gamecontroller.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    showDex = true
                } label: {
                    Label("Rogue Dex", systemImage: "book.fill")
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                SyncPanel(sync: sync)

                Text("Version \(version) (build \(build))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text("Emulation by mGBA \(MGBACore.versionString), MPL-2.0 (mgba.io). Corresponding source: github.com/mgba-emu/mgba, the commit in ci/build_mgba.sh, plus the two CMake lines in ci/mgba_patch.py. No game is included in this app.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDex) { DexSheet(sync: sync) }
    }
}
