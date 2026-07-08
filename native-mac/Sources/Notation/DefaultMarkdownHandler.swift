import Foundation
import AppKit
import UniformTypeIdentifiers

/// Manages "Notation is the default app for .md files" registration.
///
/// macOS distinguishes between two things:
///   1. CFBundleDocumentTypes declarations in our Info.plist, which let us
///      *appear* in Finder's Open With menu.
///   2. The user-visible "default app" for a given content type, which
///      controls what a double-click on a `.md` file opens.
///
/// (1) is static, declarative, and already in place.  (2) requires a runtime
/// call to `NSWorkspace.shared.setDefaultApplication(at:toOpenContentType:)`
/// and is what this enum manages.
@MainActor
enum DefaultMarkdownHandler {
    /// UserDefaults flag that ensures the one-shot auto-claim only runs
    /// on the first launch after install (or after the user resets prefs).
    private static let didClaimKey = "didClaimDefaultMarkdownHandler"

    /// The de-facto markdown UTI.  Our Info.plist imports this and lists it
    /// as one of our document types, so it must already be resolvable by
    /// Launch Services by the time this code runs.
    static var markdownType: UTType {
        UTType("net.daringfireball.markdown")
            ?? UTType(filenameExtension: "md")
            ?? .plainText
    }

    /// Call once at app startup.  If we haven't yet auto-claimed default
    /// status for `.md` on this install, do so.  Idempotent across launches
    /// thanks to the UserDefaults flag — if the user later picks a different
    /// default in Finder, we won't fight them back.
    static func claimAsDefaultIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: didClaimKey) else { return }
        UserDefaults.standard.set(true, forKey: didClaimKey)
        claimAsDefault()
    }

    /// Unconditional: request that Notation become the default handler
    /// for the markdown UTI.  macOS may show a confirmation prompt the
    /// first time this happens.  Errors are logged but not surfaced — the
    /// user can always set the default manually via Finder ▸ Get Info.
    static func claimAsDefault() {
        let bundleURL = Bundle.main.bundleURL
        let type = markdownType
        Task { @MainActor in
            do {
                try await NSWorkspace.shared.setDefaultApplication(
                    at: bundleURL,
                    toOpen: type
                )
                DebugLog.write("[default-handler] set as default for .md")
            } catch {
                let ns = error as NSError
                DebugLog.write("[default-handler] failed: \(ns.domain)#\(ns.code)")
            }
        }
    }

    /// True if we're currently the default for `.md`.  Used by Settings to
    /// show a checkmark next to the "Make Default" button.
    static func isDefault() -> Bool {
        guard
            let currentDefault = NSWorkspace.shared
                .urlForApplication(toOpen: markdownType)
        else {
            return false
        }
        return currentDefault.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }
}
