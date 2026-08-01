#if os(macOS)
import AppKit
import SwiftUI
import TableCore
import UniformTypeIdentifiers

/// DESIGN §4's menu bar extra: the table without a window — a drop target and a glance at what
/// is on it, with the main window one click away.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @State private var isImporting = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let notice = model.notice {
                Banner(notice) { model.notice = nil }
            }
            dropZone
            Divider()
            contents
            Divider()
            footer
        }
        .frame(width: 320)
        .task { await model.pollWhileVisible() }
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

    private var dropZone: some View {
        VStack(spacing: 4) {
            Image(systemName: "tray.and.arrow.down").font(.title2)
            Text("Drop files to put them on the table").font(.callout)
            Button("Choose files…") { isImporting = true }.buttonStyle(.link)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(isDropTargeted ? Color.accentColor.opacity(0.2) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
    }

    @ViewBuilder
    private var contents: some View {
        if let startupFailure = model.startupFailure {
            note(startupFailure)
        } else if !model.settings.isConfigured {
            note("No server yet — add one in settings.")
        } else if model.files.isEmpty {
            note(model.isListLoaded ? "Nothing on the table." : "Loading…")
        } else {
            files
            if let moving = movingSummary {
                Divider()
                note(moving)
            }
        }
    }

    private var files: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.files) { file in
                    ServerFileRow(file: file, download: downloadOf(file)) { model.download(file) }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    Divider()
                }
            }
        }
        .frame(maxHeight: 280)
    }

    private var footer: some View {
        HStack {
            Button("Open table", action: openMainWindow)
            Spacer()
            Button("Settings…", action: showSettings)
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.link)
        .padding(12)
    }

    /// What the window would show in its transfers section, in one line.
    private var movingSummary: String? {
        let counts = [
            (model.transfers.filter { !$0.isFinished }.count, "moving"),
            (model.transfers.filter { $0.state == .failed }.count, "failed"),
        ]
        let parts = counts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }

    private func downloadOf(_ file: TableFile) -> TransferRecord? {
        model.transfers.first { $0.direction == .download && $0.remoteID == file.id }
    }

    /// A menu bar extra's window is not the app coming to the front, so both of these say so
    /// themselves — otherwise the window they open stays behind whatever the user was in.
    private func openMainWindow() {
        NSApplication.shared.activate()
        openWindow(id: mainWindowID)
    }

    private func showSettings() {
        NSApplication.shared.activate()
        openSettings()
    }
}
#endif
