import SwiftUI

/// The root view dropped into `ContentView` as a bottom-trailing overlay.
/// Renders the persistent FAB plus the conditionally-visible chat card. The
/// card transitions in from the FAB's anchor (bottom-trailing) with a spring
/// scale/opacity combo so it feels like it "blooms" out of the ball.
struct AgentOverlay: View {
    @Environment(AgentChatController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        VStack(alignment: .trailing, spacing: 12) {
            if controller.isOpen {
                AgentCard(controller: controller)
                    .transition(
                        .scale(scale: 0.86, anchor: .bottomTrailing)
                            .combined(with: .opacity)
                    )
            }
            AgentFab(isOpen: controller.isOpen) {
                controller.toggle()
            }
        }
        .padding(.trailing, 20)
        .padding(.bottom, 20)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: controller.isOpen)
        // Escape closes the panel from anywhere it has focus.
        .onKeyPress(.escape) {
            if controller.isOpen {
                controller.isOpen = false
                return .handled
            }
            return .ignored
        }
    }
}
