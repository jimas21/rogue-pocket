import SwiftUI
import WebKit

/// Owns the on-phone Dex server and the live bridge for the app's lifetime.
@MainActor
final class DexHost: ObservableObject {
    let store = DexStore.shared
    private let emulator: Emulator
    private var bridge: LiveBridge?
    private lazy var server = LocalDexServer(
        store: store,
        bridge: { [weak self] in self?.liveBridge() },
        onStateChanged: { [weak self] in self?.stateChanged?() }
    )
    /// Called after the page saved its state, so the sync can push it to the NAS.
    var stateChanged: (() -> Void)?

    init(emulator: Emulator) {
        self.emulator = emulator
    }

    func start() { server.start() }

    private func liveBridge() -> LiveBridge? {
        if bridge == nil { bridge = LiveBridge(emulator: emulator) }
        return bridge
    }
}

/// The Rogue Dex page, served by the phone itself.
struct DexWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.086, green: 0.09, blue: 0.1, alpha: 1)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.load(URLRequest(url: LocalDexServer.pageURL, cachePolicy: .reloadIgnoringLocalCacheData))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// The Dex as a panel: half height over the game (both visible), or full height when dragged up.
struct DexSheet: View {
    @ObservedObject var sync: SyncManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Rogue Dex").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.bold()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            if DexStore.shared.isInstalled {
                DexWebView()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary)
                    Text("The Dex isn't on this phone yet.").font(.headline)
                    Text("It downloads on the next sync with your NAS, at home or over the internet. After that it works offline.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Sync now") { Task { await sync.sync("dex") } }
                        .buttonStyle(.borderedProminent)
                        .disabled(sync.syncing)
                    Text(sync.statusText).font(.caption).foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(red: 0.086, green: 0.09, blue: 0.1))
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationDragIndicator(.visible)
    }
}
