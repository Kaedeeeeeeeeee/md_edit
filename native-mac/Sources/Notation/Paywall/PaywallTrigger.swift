import Foundation

/// Cold-launch paywall trigger logic + 24-hour cooldown tracking.
///
/// Pure logic, no UI. Three usages:
///   - `shouldShowOnLaunch()` — called once from the main editor scene's
///     `.task { ... }`, decides whether to auto-present the paywall sheet.
///   - `recordDismissal()` — called from the "先用着，下次再说" button so
///     repeat cold launches within 24h don't re-pester the user.
///   - `reset()` — debug/test convenience to clear the timestamp.
enum PaywallTrigger {

    private static let lastDismissedKey = "paywallLastDismissed"
    private static let cooldown: TimeInterval = 24 * 60 * 60

    /// True iff we should auto-present the paywall on this launch.
    ///
    /// Suppressed when:
    ///   - User is already Pro (any active entitlement).
    ///   - User dismissed the paywall less than 24 hours ago.
    @MainActor
    static func shouldShowOnLaunch() -> Bool {
        if EntitlementState.shared.isPro { return false }
        guard let last = UserDefaults.standard.object(forKey: lastDismissedKey) as? Date else {
            return true
        }
        return Date().timeIntervalSince(last) > cooldown
    }

    /// Record the user dismissed the paywall. Starts the 24h cooldown.
    static func recordDismissal() {
        UserDefaults.standard.set(Date(), forKey: lastDismissedKey)
    }

    /// Reset the cooldown so the paywall re-appears on next cold launch.
    /// Intended for debug / QA use; not surfaced in UI.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: lastDismissedKey)
    }
}
