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

@MainActor
final class CloseGuard: NSObject, NSWindowDelegate {
    private let store: DocumentStore
    private weak var window: NSWindow?
    private var isClosingForReal = false

    init(store: DocumentStore) {
        self.store = store
    }

    func attach(to window: NSWindow) {
        self.window = window
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isClosingForReal { return true }
        if !store.isDirty { return true }

        let alert = NSAlert()
        alert.messageText = "You have unsaved changes."
        alert.informativeText = "Do you want to save before closing?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: // Save
            store.save()
            if !store.isDirty {
                isClosingForReal = true
                DispatchQueue.main.async { sender.close() }
            }
            return false
        case .alertSecondButtonReturn: // Cancel
            return false
        case .alertThirdButtonReturn: // Don't save
            isClosingForReal = true
            return true
        default:
            return false
        }
    }
}
