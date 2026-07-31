import SwiftUI

/// DESIGN §4's minimal confirmation: what was put on the queue, and that the app has to be
/// opened for it to go anywhere.
struct ShareConfirmationView: View {
    let intake: SharedItemsIntake
    let done: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let failure = intake.failure {
                    ContentUnavailableView(
                        "Nothing was queued",
                        systemImage: "exclamationmark.triangle",
                        description: Text(failure)
                    )
                } else if let summary = intake.summary {
                    if summary.queued.isEmpty, summary.rejected.isEmpty {
                        ContentUnavailableView("Nothing to put on the table", systemImage: "tray")
                    } else {
                        result(summary)
                    }
                } else {
                    ProgressView("Putting it on the table…")
                }
            }
            .navigationTitle("table")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done).disabled(intake.summary == nil && intake.failure == nil)
                }
            }
        }
        .task { await intake.run() }
    }

    private func result(_ summary: SharedItemsIntake.Summary) -> some View {
        List {
            if !summary.queued.isEmpty {
                Section {
                    ForEach(summary.queued, id: \.self) { name in
                        Label(name, systemImage: "checkmark.circle").lineLimit(1)
                    }
                } footer: {
                    Text(intake.hasServer
                        ? "Open Table to send \(summary.queued.count == 1 ? "it" : "them")."
                        : "Table has no server yet — open it, add one, and these go out.")
                }
            }
            if !summary.rejected.isEmpty {
                Section("Not queued") {
                    ForEach(summary.rejected, id: \.self) { reason in
                        Text(reason).font(.callout).foregroundStyle(.red)
                    }
                }
            }
        }
    }
}
