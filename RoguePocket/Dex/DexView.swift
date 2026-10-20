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
        onStateChanged: { [weak self] in self?.stateChanged?() },
        onBattle: { [weak self] on in
            if self?.inBattle != on { self?.inBattle = on }
        }
    )
    /// Called after the page saved its state, so the sync can push it to the NAS.
    var stateChanged: (() -> Void)?
    /// What the last /battle answer said, from whichever Dex page asked (the strip asks every 2 s while it shows).
    @Published private(set) var inBattle = false

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

/// The Dex's battle answer alone, for the strip under the picture: the Dex page on its Battle tab with everything
/// but the answer card hidden, so the strip always says what the Dex says. It only reads: its storage is its own and
/// its saves never leave the page, so it can never write an older state over the Dex panel's.
struct DexAnswerView: UIViewRepresentable {
    private static let readOnly = #"""
    (function () {
      var f = window.fetch.bind(window);
      window.fetch = function (input, init) {
        var m = ((init && init.method) || (input && input.method) || "GET").toUpperCase();
        if (m !== "GET" && m !== "HEAD") return Promise.resolve(new Response("{}", { status: 200 }));
        return f(input, init);
      };
    })();
    """#

    private static let answerOnly = #"""
    (function () {
      var s = document.createElement("style");
      s.textContent =
        "html,body{background:transparent!important;overflow:hidden!important}" +
        "body *{visibility:hidden!important;pointer-events:none!important}" +
        "#answer,#answer *{visibility:visible!important}" +
        "#answer{position:fixed!important;left:0!important;top:0!important;width:100vw!important;" +
        "height:100vh!important;margin:0!important;z-index:2147483647!important}" +
        "#answer .ans{height:100%!important}";
      document.head.appendChild(s);
    })();
    """#

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(
            WKUserScript(source: Self.readOnly, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addUserScript(
            WKUserScript(source: Self.answerOnly, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isUserInteractionEnabled = false
        var page = URLComponents(url: LocalDexServer.pageURL, resolvingAgainstBaseURL: false)!
        page.fragment = "battle"
        web.load(URLRequest(url: page.url!, cachePolicy: .reloadIgnoringLocalCacheData))
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
