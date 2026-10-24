import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - Server URLs and QR code

/// A server's local and network URLs, with a QR code to open it on a phone on the same network.
struct ServerURLView: View {
    @Environment(Store.self) private var store
    let pid: Int
    @State private var port: Int

    init(pid: Int, port: Int) {
        self.pid = pid
        _port = State(initialValue: port)
    }

    private var server: Server? { store.servers.first { $0.pid == pid } }

    var body: some View {
        VStack(spacing: 0) {
            SubPageHeader(title: server?.displayName ?? "Server", subtitle: subtitle)
            Divider().opacity(0.5)
            if let server {
                ScrollView {
                    VStack(spacing: 12) {
                        if server.ports.count > 1 {
                            Picker("Port", selection: $port) {
                                ForEach(server.ports, id: \.self) { Text(verbatim: ":\($0)").tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                        NetworkSection(server: server, url: server.url(for: port))
                        URLField(label: "This Mac", url: server.url(for: port).local)
                    }
                    .padding(12)
                }
                .scrollIndicators(.never)
            } else {
                EmptyState(symbol: "stop.circle", title: "The server stopped", message: "PID \(pid) is no longer running.")
                Spacer()
            }
        }
    }

    private var subtitle: String? {
        guard let server else { return nil }
        let place = server.projectName.isEmpty ? server.cwd : server.projectName
        return place.isEmpty ? "PID \(pid)" : "\(place)  ·  PID \(pid)"
    }
}

private struct NetworkSection: View {
    let server: Server
    let url: ServerURL

    var body: some View {
        if let lan = url.lan {
            VStack(spacing: 10) {
                QRCode(text: lan)
                    .frame(width: 184, height: 184)
                    .padding(10)
                    .background(.white, in: .rect(cornerRadius: 12))
                Text("Scan with a phone on the same Wi-Fi")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                URLField(label: "Network", url: lan)
            }
            .frame(maxWidth: .infinity)
            .card()
        } else if url.exposed {
            Notice(
                symbol: "wifi.slash",
                title: "This Mac isn't on a network",
                message: "Connect to Wi-Fi or Ethernet to open it on another device."
            )
        } else {
            Notice(
                symbol: "lock.laptopcomputer",
                title: "Only this Mac can open it",
                message: "Port \(url.port) listens on localhost, so a phone can't reach it.",
                hint: server.exposeHint
            )
        }
    }
}

private struct Notice: View {
    let symbol: String
    let title: String
    let message: String
    var hint: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let hint, !hint.isEmpty {
                Text(hint)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor.opacity(0.1), in: .rect(cornerRadius: 8))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 8)
        .card()
    }
}

private struct URLField: View {
    @Environment(Store.self) private var store
    let label: String
    let url: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(url)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            IconButton(symbol: "doc.on.doc", help: "Copy \(url)", size: 22) {
                Pasteboard.copy(url)
                store.showToast("Copied \(url)")
            }
            IconButton(symbol: "safari", help: "Open \(url)", size: 22) { Launcher.openURL(url) }
        }
        .card(radius: 8, padding: 6)
    }
}

/// A QR code drawn with CoreImage, scaled without smoothing so the modules stay sharp.
struct QRCode: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .accessibilityLabel("QR code for \(text)")
        }
    }

    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        // Scaled up here: SwiftUI smooths a 25-pixel image even with interpolation off.
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: output.extent.size)
    }
}
