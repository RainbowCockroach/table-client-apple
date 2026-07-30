import Foundation

private let fallbackName = "download"
private let maxSuffixes = 10_000

/// A server-declared name reduced to something safe as a single file name.
///
/// The name travels from whatever device uploaded it, so it may hold path separators or
/// control characters that would escape the destination directory.
public func safeDisplayName(_ name: String) -> String {
    let flattened = String(
        name.map { character in
            character == "/" || character == ":" || character == "\\" || character.isControl
                ? "_"
                : character
        }
    )
    .trimmingCharacters(in: .whitespaces)

    var trimmed = flattened
    while trimmed.hasSuffix(".") {
        trimmed.removeLast()
    }
    let isEmptyOrPlaceholder = trimmed.isEmpty || trimmed.allSatisfy { $0 == "." || $0 == "_" }
    return isEmptyOrPlaceholder ? fallbackName : trimmed
}

/// `desired` with ` (n)` inserted before the extension until `isTaken` says no.
public func uniqueDisplayName(_ desired: String, isTaken: (String) -> Bool) -> String {
    guard isTaken(desired) else { return desired }
    let stem: String
    let extensionWithDot: String
    if let dot = desired.lastIndex(of: "."), dot != desired.startIndex {
        stem = String(desired[desired.startIndex..<dot])
        extensionWithDot = String(desired[dot...])
    } else {
        stem = desired
        extensionWithDot = ""
    }
    for suffix in 1...maxSuffixes {
        let candidate = "\(stem) (\(suffix))\(extensionWithDot)"
        if !isTaken(candidate) { return candidate }
    }
    return "\(stem) (\(UUID().uuidString))\(extensionWithDot)"
}

private extension Character {
    var isControl: Bool {
        unicodeScalars.allSatisfy { $0.properties.generalCategory == .control }
    }
}
