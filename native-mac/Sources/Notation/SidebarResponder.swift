import SwiftUI
import AppKit

/// Lets a SwiftUI file-tree row promote the sidebar's AppKit responder view
/// to first responder on tap, so the standard Edit-menu Cut/Copy/Paste/Delete
/// validate against the file selection while the sidebar is focused.
final class SidebarResponderHandle {
    weak var view: NSView?

    @MainActor
    func makeKey() {
        guard let view, let window = view.window else { return }
        if window.firstResponder !== view {
            window.makeFirstResponder(view)
        }
    }
}

private struct SidebarResponderHandleKey: EnvironmentKey {
    // Placeholder fallback for views read without an injected handle; its
    // `view` stays nil so `makeKey()` no-ops.  Real handles are the per-
    // SidebarView `@State` instances injected via `.environment`.
    nonisolated(unsafe) static let defaultValue = SidebarResponderHandle()
}

extension EnvironmentValues {
    /// Shared handle the file-tree rows use to claim key focus on tap.
    var sidebarResponderHandle: SidebarResponderHandle {
        get { self[SidebarResponderHandleKey.self] }
        set { self[SidebarResponderHandleKey.self] = newValue }
    }
}

/// AppKit first-responder backing the sidebar.  Implements the standard
/// `copy:` / `cut:` / `paste:` action selectors so that when the sidebar
/// holds key focus, the Edit-menu forwarding commands (which call
/// `NSApp.sendAction`) route to file operations — and route to the editor's
/// WKWebView when it's focused instead.
final class SidebarResponderView: NSView {
    weak var store: AppModel?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // 51 = delete (⌫), 117 = forward delete.
        if event.keyCode == 51 || event.keyCode == 117,
           !(store?.sidebar.selection.isEmpty ?? true) {
            store?.deleteSelection()
            return
        }
        super.keyDown(with: event)
    }

    // Cut/Copy are pure selection→clipboard moves (SidebarState); Paste
    // performs file operations, so it routes through the store.
    @objc func copy(_ sender: Any?) { store?.sidebar.copySelection() }
    @objc func cut(_ sender: Any?) { store?.sidebar.cutSelection() }
    @objc func paste(_ sender: Any?) { store?.paste(into: nil) }
}

struct SidebarResponder: NSViewRepresentable {
    let store: AppModel
    let handle: SidebarResponderHandle

    func makeNSView(context: Context) -> SidebarResponderView {
        let view = SidebarResponderView()
        view.store = store
        handle.view = view
        return view
    }

    func updateNSView(_ nsView: SidebarResponderView, context: Context) {
        nsView.store = store
    }
}
