import Foundation
import TableCore

func formatBytes(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .file))
}

func describe(_ file: TableFile) -> String {
    switch file.state {
    // Conformance rule 15: no TTL until the upload finalizes, so there is nothing to count down.
    case .uploading:
        return "\(formatBytes(file.bytesReceived)) of \(formatBytes(file.size)) · uploading"
    case .available:
        return formatBytes(file.size)
    }
}

func describe(_ transfer: TransferRecord) -> String {
    switch transfer.state {
    case .queued:
        return "Queued"
    case .running:
        return "\(formatBytes(transfer.bytesDone)) of \(formatBytes(transfer.size))"
    case .verifying:
        return transfer.direction == .upload ? "Finishing" : "Verifying"
    case .done:
        return transfer.publishedName.map { "Saved to \(publishDestination) as \($0)" } ?? "Sent"
    // The queue owns the retry; the button is only for someone who would rather not wait.
    case .failed:
        return transfer.failure?.retryable == true ? "Retrying soon" : "Failed"
    }
}

func fraction(_ done: Int64, of total: Int64) -> Double {
    guard total > 0 else { return 0 }
    return min(max(Double(done) / Double(total), 0), 1)
}

#if os(macOS)
private let publishDestination = "Downloads"
#else
private let publishDestination = "Files"
#endif
