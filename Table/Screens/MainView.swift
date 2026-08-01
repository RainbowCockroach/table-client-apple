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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isShowingSettings = false
    #endif

    var body: some View {
        // DESIGN §4: the picker is the intake both platforms share — the macOS drop and the
        // iOS share extension sit alongside it.
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
        layout
            .onAppear { model.start() }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await model.adoptSharedQueue()
                await model.pollWhileVisible()
            }
    }

    /// DESIGN §4: a regular-width iPad shows the table and the queue side by side; everything
    /// narrower stacks them in one list.
    @ViewBuilder
    private var layout: some View {
        #if os(macOS)
        stacked
        #else
        if horizontalSizeClass == .regular {
            split
        } else {
            stacked
        }
        #endif
    }

    private var stacked: some View {
        NavigationStack {
            VStack(spacing: 0) {
                banners
                table {
                    filesSection
                    transfersSection
                }
            }
            .navigationTitle("table")
            .toolbar { toolbar }
        }
    }

    #if !os(macOS)
    private var split: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                banners
                table { filesSection }
            }
            .navigationTitle("table")
            .toolbar { toolbar }
        } detail: {
            transfersDetail.navigationTitle("Transfers")
        }
    }

    @ViewBuilder
    private var transfersDetail: some View {
        if model.transfers.isEmpty {
            ContentUnavailableView(
                "Nothing moving",
                systemImage: "arrow.up.arrow.down",
                description: Text("Take a file from the table, or put one on it.")
            )
        } else {
            List { transfersSection }
        }
    }
    #endif

    @ViewBuilder
    private func table<Sections: View>(@ViewBuilder sections: () -> Sections) -> some View {
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
            List { sections() }
                .refreshable { await model.refresh() }
        }
    }

    private var filesSection: some View {
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
    }

    @ViewBuilder
    private var transfersSection: some View {
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
