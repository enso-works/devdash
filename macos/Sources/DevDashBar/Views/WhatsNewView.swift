import SwiftUI

/// The welcome tour on a fresh install, or the highlights of each version since the last one seen.
struct WhatsNewView: View {
    @Environment(Store.self) private var store
    @State private var note: (welcome: Bool, releases: [WhatsNew.Release])?

    var body: some View {
        let welcome = note?.welcome ?? false
        VStack(spacing: 0) {
            SubPageHeader(title: welcome ? "Welcome to devdash" : "What's new")
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if welcome {
                        section(title: nil, entries: WhatsNew.tour)
                    } else {
                        ForEach(note?.releases ?? [], id: \.version) { release in
                            section(title: "Version \(release.version)", entries: release.entries)
                        }
                    }
                    PillButton(title: "Got it", prominent: true) { store.pop() }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollIndicators(.never)
        }
        .onAppear {
            // Captured before marking it seen. Opened from the menu with nothing pending, it shows the latest release.
            note = store.whatsNew ?? (false, Array(WhatsNew.releases.prefix(1)))
            store.markWhatsNewSeen()
        }
    }

    @ViewBuilder
    private func section(title: String?, entries: [WhatsNew.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }
            ForEach(entries, id: \.self) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: entry.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28, height: 28)
                        .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(.system(size: 12.5, weight: .semibold))
                        Text(entry.detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
