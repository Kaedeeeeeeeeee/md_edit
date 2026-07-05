import SwiftUI
import AppKit

/// Root view of an external-file document window (B2 phase 2): a bare
/// editor — no sidebar, no file tree — for one file living outside the
/// workspace.  Typora/TextEdit feel: opens fast, really closes.
///
/// Environment: receives the app-level `AppModel` / `PaywallStore` /
/// `EntitlementState` from the scene, but creates its own
/// `AgentChatController` + `EditorJSBridge` pair — the bridge must point
/// at THIS window's WKWebView, and chat history is keyed per document
/// URL so nothing is shared with the main window anyway.
struct DocumentWindowView: View {
    let fileURL: URL
    let session: DocumentSession

    @Environment(AppModel.self) private var store
    @State private var closeGuard: DocumentCloseGuard?
    @State private var agentChat: AgentChatController

    init(fileURL: URL, session: DocumentSession) {
        self.fileURL = fileURL
        self.session = session
        _agentChat = State(initialValue: AgentChatController(bridge: EditorJSBridge()))
    }

    var body: some View {
        EditorWebView()
            .overlay(alignment: .top) {
                if session.localImageAuthNeeded {
                    LocalImageAccessBanner(
                        onAllow: { session.authorizeCurrentDocumentFolder() },
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.18)) {
                                session.localImageAuthNeeded = false
                            }
                        }
                    )
                    .padding(.top, 12)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: session.localImageAuthNeeded)
            .overlay(alignment: .bottomTrailing) {
                AgentOverlay()
            }
            // Menu-command routing: ⌘S / ⌘⇧S resolve against this session
            // while this window is key (FileCommands reads the focused value).
            .focusedSceneValue(\.documentSession, session)
            .background(
                WindowAccessor { window in
                    let guardian = closeGuard ?? DocumentCloseGuard(
                        session: session,
                        onClose: { [weak store] in
                            store?.documentWindows.close(fileURL)
                        }
                    )
                    guardian.attach(to: window)
                    closeGuard = guardian
                    // Window title / dirty dot are set on the NSWindow
                    // directly: this view is hosted in an NSHostingController
                    // (see DocumentWindowManager), so SwiftUI's
                    // navigationTitle has no scene to write into.
                    window.title = title
                    window.isDocumentEdited = session.isDirty
                }
            )
            .onChange(of: session.isDirty) { _, dirty in
                closeGuard?.window?.isDocumentEdited = dirty
                closeGuard?.window?.title = title
            }
            .onAppear {
                agentChat.bind(to: fileURL)
            }
            // Environment applied outermost so the editor AND the overlays
            // (banner, agent card) all see this window's session/controller.
            .environment(session)
            .environment(agentChat)
            .frame(minWidth: 480, minHeight: 360)
    }

    private var title: String {
        fileURL.deletingPathExtension().lastPathComponent
    }
}

/// Builds the `NSWindow` that hosts a `DocumentWindowView`.  Injected into
/// `DocumentWindowManager.makeWindow` by `NotationApp` so window creation
/// has the app-level environment objects it needs.
///
/// Uses `NSHostingController` rather than a SwiftUI `WindowGroup` because
/// `openWindow` can't open a document window during cold launch (see the
/// manager's doc comment).  The SwiftUI content is otherwise identical;
/// only the hosting differs.
@MainActor
enum DocumentWindowHost {
    /// Cascades successive windows so multiple open documents don't stack
    /// exactly on top of each other.
    private static var cascadePoint = NSPoint.zero

    static func makeWindow(
        fileURL: URL,
        session: DocumentSession,
        store: AppModel,
        paywall: PaywallStore
    ) -> NSWindow {
        let root = DocumentWindowView(fileURL: fileURL, session: session)
            .environment(store)
            .environment(paywall)
            .environment(EntitlementState.shared)

        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = fileURL.deletingPathExtension().lastPathComponent
        // The manager is the sole owner; releasing on close would double-free
        // against the entry's strong reference.
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 640))
        if cascadePoint == .zero {
            window.center()
        }
        cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        return window
    }
}

/// Close guard for document windows.  Same three-way dirty prompt as the
/// main window's `CloseGuard`, but the outcome is a REAL close: document
/// windows are transient, there is no scene state worth preserving via
/// orderOut, and `windowWillClose` tears down the manager entry (pending
/// autosave cancelled, security scope released).
@MainActor
final class DocumentCloseGuard: NSObject, NSWindowDelegate {
    private let session: DocumentSession
    private let onClose: () -> Void
    private(set) weak var window: NSWindow?

    init(session: DocumentSession, onClose: @escaping () -> Void) {
        self.session = session
        self.onClose = onClose
    }

    func attach(to window: NSWindow) {
        self.window = window
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard session.isDirty else { return true }

        let alert = NSAlert()
        alert.messageText = String(localized: "You have unsaved changes.")
        alert.informativeText = String(localized: "Do you want to save before closing?")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Don’t Save"))

        switch alert.runModal() {
        case .alertFirstButtonReturn: // Save
            session.save()
            // Save can be a no-op if a Save As panel was cancelled — only
            // let the window die once the content is actually settled.
            return !session.isDirty
        case .alertThirdButtonReturn: // Don't save
            // Kill any scheduled autosave BEFORE allowing the close, or it
            // can fire against the discarded content between now and the
            // window teardown.
            session.cancelPendingAutoSave()
            session.isDirty = false
            return true
        default: // Cancel
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

/// Non-blocking banner offering one-time folder access so a document's
/// local images can render under the sandbox.  The grant is remembered
/// per directory tree (`DocumentDirBookmarks`), so this appears only once
/// per folder.  Lives here because after phase-2 routing only document
/// windows can host files outside authorised roots — the main window
/// shows workspace files exclusively.
struct LocalImageAccessBanner: View {
    let onAllow: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("This document references local images.")
                    .font(.callout)
                    .fontWeight(.medium)
                Text("Allow access to its folder so they can be displayed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(action: onAllow) {
                Text("Allow Access…")
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Dismiss"))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .frame(maxWidth: 540)
    }
}
