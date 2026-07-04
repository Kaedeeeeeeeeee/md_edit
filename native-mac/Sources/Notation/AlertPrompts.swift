import AppKit

/// Small modal-alert helpers shared by the document and workspace layers.
/// Kept dumb on purpose: every call is a synchronous `runModal`, matching
/// how the old `DocumentStore` presented errors and name prompts.
@MainActor
enum AppAlerts {
    /// One-button warning alert (implicit OK).
    static func present(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Text-field prompt used by New File / New Folder / legacy Rename.
    /// Returns the trimmed name, or nil on cancel.
    static func promptForName(title: String, placeholder: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = placeholder
        field.stringValue = defaultValue
        // Select stem so ".md" extension survives unless user replaces all.
        if let editor = field.currentEditor() as? NSTextView {
            editor.selectAll(nil)
        }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
