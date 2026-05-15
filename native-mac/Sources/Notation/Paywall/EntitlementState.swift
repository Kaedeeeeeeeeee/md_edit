import Foundation
import Observation

/// Single source of truth for whether the user has unlocked Notation Pro.
///
/// Derived from StoreKit transactions; not persisted independently. On every
/// cold launch, `PaywallStore.refreshEntitlements()` reads
/// `Transaction.currentEntitlements` and calls `update(activeTier:)`. Treat
/// this object as a cached projection of StoreKit's authoritative state, not
/// a separate store.
///
/// All access is main-actor isolated because SwiftUI views observe this and
/// must mutate on the main thread. The few non-UI call sites that read
/// `isPro` (the AI gating guards in EditorWebView / AgentChatController) all
/// run in main-thread delegate / Button-action contexts, so no hop needed.
@MainActor
@Observable
final class EntitlementState {

    /// App-wide singleton. Also injected via `.environment(EntitlementState.shared)`
    /// at the scene root so SwiftUI views can `@Environment(EntitlementState.self)`.
    static let shared = EntitlementState()

    /// The three product types we sell. Raw values intentionally equal the
    /// StoreKit product IDs so lookup-by-tier and lookup-by-product-id
    /// collapse into the same code path.
    enum ProTier: String, CaseIterable, Identifiable {
        case lifetime = "com.shifengzhang.notation.lifetime"
        case yearly = "com.shifengzhang.notation.yearly"
        case monthly = "com.shifengzhang.notation.monthly"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .lifetime: return String(localized: "终身买断")
            case .yearly:   return String(localized: "年订阅")
            case .monthly:  return String(localized: "月订阅")
            }
        }

        /// True for the two auto-renewable subscriptions; false for lifetime.
        var isSubscription: Bool {
            self == .monthly || self == .yearly
        }
    }

    /// True iff the user has any unexpired entitlement (lifetime OR active sub).
    private(set) var isPro: Bool = false

    /// Which tier is currently active. nil when `isPro == false`. When more
    /// than one entitlement is present, lifetime wins (it's the strongest);
    /// otherwise we prefer the longer-period subscription.
    private(set) var activeTier: ProTier? = nil

    private init() {}

    /// Called by `PaywallStore` after every transaction event, restore, or
    /// app-launch refresh. Single mutator so the @Observable updates fire
    /// once per state change instead of twice.
    func update(activeTier: ProTier?) {
        self.activeTier = activeTier
        self.isPro = (activeTier != nil)
    }
}
