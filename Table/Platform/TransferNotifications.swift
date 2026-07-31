import Foundation
import TableCore
import UserNotifications

/// DESIGN §4: what a transfer that settled while the user was elsewhere gets to say.
///
/// The system shows these only when the app is not in front of the user, which is exactly the
/// case they exist for — a background transfer that finished after the app was suspended.
struct TransferNotifications {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func post(_ transfer: TransferRecord) {
        let content = UNMutableNotificationContent()
        content.title = transfer.name
        content.body = summary(of: transfer)
        center.add(UNNotificationRequest(identifier: transfer.id, content: content, trigger: nil))
    }

    private func summary(of transfer: TransferRecord) -> String {
        if let failure = transfer.failure {
            return failure.message
        }
        switch transfer.direction {
        case .upload:
            return "It's on the table."
        case .download:
            #if os(macOS)
            return "Saved to \(transfer.publishedName ?? transfer.name) in Downloads."
            #else
            return "Saved to Files."
            #endif
        }
    }
}

/// Which transfers have settled since the last look.
struct SettledTransfers {
    private var seen: Set<String> = []

    /// What was already finished when this launch started is nobody's news.
    mutating func takeStock(of transfers: [TransferRecord]) {
        seen = ids(finishedIn: transfers)
    }

    mutating func newlySettled(in transfers: [TransferRecord]) -> [TransferRecord] {
        let news = transfers.filter { $0.isFinished && !seen.contains($0.id) }
        seen = ids(finishedIn: transfers)
        return news
    }

    private func ids(finishedIn transfers: [TransferRecord]) -> Set<String> {
        Set(transfers.filter(\.isFinished).map(\.id))
    }
}
