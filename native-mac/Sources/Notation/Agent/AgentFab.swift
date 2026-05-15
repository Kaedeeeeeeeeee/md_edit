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
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tint)
                .rotationEffect(.degrees(isOpen ? 180 : 0))
                .animation(.spring(response: 0.45, dampingFraction: 0.7), value: isOpen)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(isOpen ? "Close AI assistant (⌘⇧J)" : "Open AI assistant (⌘⇧J)")
    }
}
