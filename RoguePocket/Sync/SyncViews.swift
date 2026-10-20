import SwiftUI

/// The NAS box on the home screen: pairing state, the last result, and Sync now.
struct SyncPanel: View {
    @ObservedObject var sync: SyncManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: sync.paired ? "externaldrive.fill.badge.checkmark" : "externaldrive.badge.xmark")
                    .foregroundStyle(sync.paired ? .green : .secondary)
                Text("NAS sync").font(.headline)
                Spacer()
                if sync.syncing { ProgressView() }
            }
            Text(sync.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let last = sync.lastSync {
                Text("Last synced \(last.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if sync.paired {
                Button {
                    Task { await sync.sync("button") }
                } label: {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .disabled(sync.syncing)
                .padding(.top, 2)
            } else {
                Text("To pair: on a computer at home, open the rogue-sync pairing page on the NAS (port 8092, /pair) and point the iPhone camera at the code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: 460, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Asks which save to keep. Whatever is not kept is backed up (Saves/Backups on the phone, backups/ on the NAS).
struct SaveChoiceView: View {
    let choice: SaveChoice
    let sync: SyncManager

    private var nasDate: Date { Date(timeIntervalSince1970: TimeInterval(choice.nas.mtime)) }

    private var phoneIsAhead: Bool {
        guard let p = choice.phoneCounter, let n = choice.nas.counter else { return false }
        return p > n
    }

    private var nasIsAhead: Bool {
        guard let p = choice.phoneCounter, let n = choice.nas.counter else { return false }
        return n > p
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            Text(message).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                row("This phone", counter: choice.phoneCounter, date: choice.phoneDate, ahead: phoneIsAhead,
                    icon: "iphone")
                row("NAS (Steam Deck, Steam Machine)", counter: choice.nas.counter, date: nasDate, ahead: nasIsAhead,
                    icon: "externaldrive")
            }

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                switch choice.kind {
                case .nasNewerPlaying:
                    wide("Load the NAS save now", prominent: true) { sync.useNAS(choice) }
                    wide("Keep playing", prominent: false) { sync.decideLater() }
                case .nasOlder:
                    wide("Keep this phone's save", prominent: true) { sync.keepPhone(choice) }
                    wide("Use the older NAS save", prominent: false) { sync.useNAS(choice) }
                    wide("Decide later", prominent: false) { sync.decideLater() }
                case .bothChanged, .firstPairing:
                    wide("Keep this phone's save", prominent: phoneIsAhead) { sync.keepPhone(choice) }
                    wide("Use the NAS save", prominent: nasIsAhead) { sync.useNAS(choice) }
                    wide("Decide later", prominent: false) { sync.decideLater() }
                }
            }
            Text("The save you don't keep is backed up, not deleted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
    }

    private var title: String {
        switch choice.kind {
        case .bothChanged: return "Both saves changed"
        case .nasOlder: return "The NAS save went backwards"
        case .nasNewerPlaying: return "Newer save on the NAS"
        case .firstPairing: return "Which save is your run?"
        }
    }

    private var message: String {
        switch choice.kind {
        case .bothChanged:
            return "This phone and another device both saved since the last sync. Keep one; the other is backed up."
        case .nasOlder:
            return "Another device wrote back an older copy of the save. That usually means the Steam Deck still had the game open. Keeping this phone's save is almost always right."
        case .nasNewerPlaying:
            return "Another device saved since this phone last synced. Loading it restarts the game from that save; anything not saved here is lost."
        case .firstPairing:
            return "This phone already has a save, and it differs from the one on the NAS."
        }
    }

    private func row(_ name: String, counter: Int?, date: Date?, ahead: Bool, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.bold())
                Text(detail(counter: counter, date: date)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if ahead {
                Text("More saves").font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.green.opacity(0.25), in: Capsule())
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func detail(counter: Int?, date: Date?) -> String {
        var parts: [String] = []
        if let counter { parts.append("Save #\(counter)") }
        if let date { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        return parts.isEmpty ? "No details" : parts.joined(separator: " · ")
    }

    private func wide(_ label: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Group {
            if prominent {
                Button(action: action) { Text(label).frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
            } else {
                Button(action: action) { Text(label).frame(maxWidth: .infinity) }.buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
    }
}
