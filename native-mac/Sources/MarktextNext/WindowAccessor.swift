import SwiftUI
import AppKit

/// Bridges the current SwiftUI scene's NSWindow to a coordinator block so we
/// can install delegates and handle close/dirty checks.
struct WindowAccessor: NSViewRepresentable {
    let onAttach: (NSWindow) -> Void

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onAttach(window)
            } else {
                // Window may not be set yet on first layout pass.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if let w = view.window { onAttach(w) }
                }
            }
        }
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
}

/// Intercepts the main editor window's close button.
///
/// Behaviour: we *never* truly close the window via the red button.  Instead
/// we hide it (`orderOut`), which keeps the SwiftUI scene alive in memory
/// so a later file-open event from Finder can re-show it (`makeKeyAndOrderFront`).
/// Without this, closing the main window destroys the SwiftUI Window scene
/// and the only remaining default scene is the picker — Finder "Open With"
/// would route the URL to the picker, which awkwardly flashes.
///
/// Cmd+Q goes through `applicationShouldTerminate`, which bypasses
/// `windowShouldClose`, so it still quits the app cleanly.
@MainActor
final class CloseGuard: NSObject, NSWindowDelegate {
    private let store: DocumentStore
    private weak var window: NSWindow?

    init(store: DocumentStore) {
        self.store = store
    }

    func attach(to window: NSWindow) {
        self.window = window
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // If we're dirty, give the user the standard three-way choice before
        // hiding.  Whether they save, discard, or cancel, we hide rather than
        // destroy so re-opening a file later doesn't need to recreate the
        // scene from scratch.
        if store.isDirty {
            let alert = NSAlert()
            alert.messageText = "You have unsaved changes."
            alert.informativeText = "Do you want to save before closing?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don’t Save")

            switch alert.runModal() {
            case .alertFirstButtonReturn: // Save
                store.save()
                if store.isDirty {
                    // Save was cancelled (e.g., user dismissed Save As); keep
                    // the window open so they don't lose anything.
                    return false
                }
                sender.orderOut(nil)
                return false
            case .alertSecondButtonReturn: // Cancel
                return false
            case .alertThirdButtonReturn: // Don't save
                // Race fix: if an autosave was scheduled before the user
                // discarded, fire-after-orderOut would zombie-write the
                // discarded content.  Kill the pending task first.
                store.cancelPendingAutoSave()
                store.isDirty = false
                sender.orderOut(nil)
                return false
            default:
                return false
            }
        }

        sender.orderOut(nil)
        return false
    }
}
