import SwiftUI

/// The floating action button. Anchored at the bottom-right of the editor and
/// stays put regardless of card state — clicking it just toggles the card.
/// Icon does a 180° spring rotation on open/close to telegraph the state
/// change without animating the card's slide-in (which carries its own
/// animation).
struct AgentFab: View {
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isOpen ? 180 : 0))
                .animation(.spring(response: 0.45, dampingFraction: 0.7), value: isOpen)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(FloatingGlassButtonStyle())
        .help(isOpen ? "Close AI assistant (⌘⇧J)" : "Open AI assistant (⌘⇧J)")
    }
}

private struct FloatingGlassButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
        }
    }
}
