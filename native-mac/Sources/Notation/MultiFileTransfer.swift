import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Custom UTI for intra-app sidebar drag-drop.  Declaring it as an
/// exported type via `UTType(exportedAs:)` makes the system register
/// it the first time we drag, which gives the drop destination a
/// reliable way to find our payload among the many `public.data` items
/// macOS shovels through the pasteboard during a drag.
extension UTType {
    static let notationFileRow = UTType(exportedAs: "com.shifengzhang.notation.filerow")
}

/// Sendable Codable wrapper around an array of URLs that conforms to
/// `Transferable` with multiple representations so it works for both:
///   - intra-app drag-drop (sidebar row → folder row, sidebar row → sidebar root)
///   - drag OUT to Finder (Finder accepts .fileURL representation)
struct MultiFileTransfer: Codable, Sendable {
    let urls: [URL]
}

extension MultiFileTransfer: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        // Primary: our custom UTI so the in-app dropDestination finds us
        // unambiguously.  CodableRepresentation handles the JSON encode/
        // decode round-trip on its own.
        CodableRepresentation(contentType: .notationFileRow)

        // Secondary: surface the first URL as .fileURL so Finder etc.
        // accept the drag-out (single URL only — Finder gets the head).
        ProxyRepresentation { transfer in
            transfer.urls.first ?? URL(fileURLWithPath: "/")
        }
    }
}
