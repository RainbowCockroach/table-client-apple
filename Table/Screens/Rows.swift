import SwiftUI
import TableCore

/// The rows the window, the split layout and the macOS menu bar extra all draw.
struct ServerFileRow: View {
    let file: TableFile
    let download: TransferRecord?
    let take: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).lineLimit(1)
                HStack(spacing: 4) {
                    Text(describe(file))
                    if let expiresAt = file.expiresAt {
                        Text("·")
                        Expiry(expiresAt)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                // Rule 15: an uploading file shows live progress and is downloadable anyway.
                if file.state == .uploading {
                    ProgressView(value: fraction(file.bytesReceived, of: file.size))
                }
            }
            Spacer(minLength: 12)
            if let download, download.state != .failed {
                Text(describe(download)).font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Take", action: take).buttonStyle(.bordered)
            }
        }
    }
}

struct TransferRow: View {
    let transfer: TransferRecord
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(transfer.direction == .upload ? "↑" : "↓") \(transfer.name)").lineLimit(1)
                Text(describe(transfer)).font(.caption).foregroundStyle(.secondary)
                if transfer.state == .running || transfer.state == .verifying {
                    ProgressView(value: fraction(transfer.bytesDone, of: transfer.size))
                }
                if let failure = transfer.failure {
                    Text(failure.message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 12)
            #if !os(macOS)
            // DESIGN §3: publish puts the file in Files; export is its user-chosen-location half.
            if let published = transfer.publishedPath, transfer.state == .done {
                ShareLink(item: URL(filePath: published)) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
            #endif
            if transfer.state == .failed {
                Button("Retry now", systemImage: "arrow.clockwise", action: retry)
            }
            if transfer.isFinished {
                Button("Dismiss", systemImage: "xmark", action: dismiss)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
}

/// The countdown of DESIGN §5. Root DESIGN §2: `expires_at` is server time and the client only
/// displays it, so a device clock that is off shows a wrong number and nothing worse.
struct Expiry: View {
    private let expiresAt: Date

    init(_ expiresAt: Date) {
        self.expiresAt = expiresAt
    }

    var body: some View {
        if expiresAt > .now {
            Text("expires in ")
            Text(timerInterval: Date.now...expiresAt, countsDown: true, showsHours: false)
        } else {
            Text("expiring")
        }
    }
}

struct SectionHeader<Action: View>: View {
    private let title: String
    private let action: Action

    init(_ title: String, @ViewBuilder action: () -> Action) {
        self.title = title
        self.action = action()
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            action.buttonStyle(.borderless)
        }
    }
}

struct Banner: View {
    private let message: String
    private let dismiss: (() -> Void)?

    init(_ message: String, dismiss: (() -> Void)? = nil) {
        self.message = message
        self.dismiss = dismiss
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(message).font(.callout)
            Spacer(minLength: 8)
            if let dismiss {
                Button("Dismiss", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.15))
    }
}
