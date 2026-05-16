import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Sendable Codable wrapper around an array of URLs that conforms to
/// `Transferable` with multiple representations so it works for both:
///   - intra-app drag-drop (sidebar row → folder row, sidebar row → sidebar root)
///   - drag OUT to Finder (Finder accepts .fileURL representation)
///
/// Used by SidebarView's `.draggable { ... }` closures and matching
/// `.dropDestination(for: MultiFileTransfer.self)` modifiers.
struct MultiFileTransfer: Codable, Sendable {
    let urls: [URL]
}

extension MultiFileTransfer: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        // Primary: JSON-encoded for intra-app reliable round-trip.
        CodableRepresentation(contentType: .data)
        // Secondary: surface the first URL as .fileURL so Finder etc accept the drop.
        ProxyRepresentation { transfer in
            transfer.urls.first ?? URL(fileURLWithPath: "/")
        }
    }
}
