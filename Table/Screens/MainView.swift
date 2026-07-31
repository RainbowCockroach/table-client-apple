import SwiftUI
import TableCore
import UniformTypeIdentifiers

/// DESIGN §5's main screen: what is on the table, and what this device is moving.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    @State private var isImporting = false

    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    @State private var isDropTargeted = false
    #else
    @State private var isShowingSettings = false
    #endif

    var body: some View {
        // DESIGN §4: the picker is the intake both platforms share — the macOS drop and the
        // iOS share extension (C4) sit alongside it.
        platformScreen
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls): model.add(urls)
                case .failure(let error): model.notice = error.localizedDescription
                }
            }
    }

    private var platformScreen: some View {
        #if os(macOS)
        screen
            .dropDestination(for: URL.self) { urls, _ in
                model.add(urls)
                return true
            } isTargeted: {
                isDropTargeted = $0
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
        #else
        screen
            .sheet(isPresented: $isShowingSettings) {
                NavigationStack {
                    SettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { isShowingSettings = false }
                            }
                        }
                }
            }
        #endif
    }

    private var screen: some View {
        NavigationStack {
            VStack(spacing: 0) {
                banners
                content
            }
            .navigationTitle("table")
            .toolbar { toolbar }
        }
        .task { await model.start() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.pollWhileActive()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let startupFailure = model.startupFailure {
            ContentUnavailableView(
                "table can't start",
                systemImage: "exclamationmark.triangle",
                description: Text(startupFailure)
            )
        } else if !model.settings.isConfigured {
            ContentUnavailableView {
                Label("No server yet", systemImage: "gearshape")
            } description: {
                Text("Add a host URL and API key to see what's on the table.")
            } actions: {
                Button("Open settings", action: showSettings)
            }
        } else {
            table
        }
    }

    private var table: some View {
        List {
            Section {
                if model.files.isEmpty {
                    Text(model.isListLoaded ? "Nothing on the table." : "Loading…")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.files) { file in
                    ServerFileRow(file: file, download: downloadOf(file)) { model.download(file) }
                }
            } header: {
                SectionHeader("On the table") {
                    if !model.files.isEmpty {
                        Button("Take all") { model.downloadAll() }
                    }
                }
            }
            if !model.transfers.isEmpty {
                Section {
                    ForEach(model.transfers) { transfer in
                        TransferRow(
                            transfer: transfer,
                            retry: { model.retry(transfer.id) },
                            dismiss: { model.dismiss(transfer.id) }
                        )
                    }
                } header: {
                    SectionHeader("Transfers") {
                        if model.transfers.contains(where: \.isFinished) {
                            Button("Clear") { model.dismissFinished() }
                        }
                    }
                }
            }
        }
        .refreshable { await model.refresh() }
    }

    @ViewBuilder
    private var banners: some View {
        if let listError = model.listError {
            Banner(listError)
        }
        if let notice = model.notice {
            Banner(notice) { model.notice = nil }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button("Put files on the table", systemImage: "plus") { isImporting = true }
        }
        #if !os(macOS)
        ToolbarItem {
            Button("Settings", systemImage: "gearshape", action: showSettings)
        }
        #endif
    }

    /// A file being downloaded appears in both lists; the row then shows the transfer's state
    /// instead of offering to start it again.
    private func downloadOf(_ file: TableFile) -> TransferRecord? {
        model.transfers.first { $0.direction == .download && $0.remoteID == file.id }
    }

    private func showSettings() {
        #if os(macOS)
        openSettings()
        #else
        isShowingSettings = true
        #endif
    }
}

private struct ServerFileRow: View {
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

private struct TransferRow: View {
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
private struct Expiry: View {
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

private struct SectionHeader<Action: View>: View {
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

private struct Banner: View {
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
