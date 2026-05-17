import Foundation
import StoreKit
import Observation

/// StoreKit 2 integration layer for Notation's paywall.
///
/// Owns three responsibilities:
///   1. Load the three products (monthly / yearly / lifetime) from the
///      App Store (or the local StoreKit Configuration File at dev time).
///   2. Initiate purchases and surface results to the UI.
///   3. Observe `Transaction.updates` for the App's entire lifetime so we
///      catch renewals, refunds, family-share changes, and out-of-band
///      sales (Manage Subscriptions sheet, etc.). Every event triggers a
///      refresh of `EntitlementState`.
///
/// Created once in `NotationApp.init()` and held as `@State` so the observer
/// task lives for the App's full lifetime. Also injected via
/// `.environment(...)` so any SwiftUI view (the paywall, the Settings
/// banner, the menu items) can react to product / purchase / loading state.
@MainActor
@Observable
final class PaywallStore {

    enum LoadState {
        case idle
        case loading
        case loaded
        case failed(Error)
    }

    /// True while the paywall sheet is presented on the main editor window.
    /// Read by `AgentOverlay` so the FAB (which uses `.glassEffect(.interactive())`)
    /// can collapse itself out of the way — Liquid Glass's interactive
    /// hover-recomposition fights Xcode's local StoreKit Testing dialog and
    /// hides the dialog's purchase button when the cursor is anywhere in the
    /// editor window.  Cleanly handled by removing the FAB from the layer
    /// stack for the duration of the sheet.
    var isPaywallVisible: Bool = false

    enum PurchaseError: LocalizedError {
        case productNotFound
        case userCancelled
        case pending
        case verificationFailed
        case unknown(Error)

        var errorDescription: String? {
            switch self {
            case .productNotFound:   return String(localized: "Product not found. Please try again later.")
            case .userCancelled:     return String(localized: "Cancelled.")
            case .pending:           return String(localized: "Purchase pending approval (e.g., parental controls). Will complete automatically.")
            case .verificationFailed: return String(localized: "Transaction verification failed. Please try again.")
            case .unknown(let err):  return err.localizedDescription
            }
        }
    }

    /// Loaded products, sorted in display order (lifetime first, then yearly,
    /// then monthly — which is the order users see in the paywall card grid).
    private(set) var products: [Product] = []

    private(set) var loadState: LoadState = .idle

    /// Set while a `buy()` call is in flight, used by the paywall UI to
    /// show a spinner on the in-progress tier and disable the others.
    private(set) var purchasingProductID: String? = nil

    /// True while `restore()` is in flight.
    private(set) var isRestoring: Bool = false

    /// Long-lived transaction observer. We hold the Task only to keep it
    /// strongly retained — never cancel it manually, because this object
    /// is an App-lifetime singleton (created once in NotationApp.init,
    /// held as @State, never deinit'd in practice). The task captures
    /// `[weak self]` so it harmlessly no-ops if self ever does go away.
    private var observerTask: Task<Void, Never>?

    init() {
        // Long-lived transaction observer for the App's lifetime. Starts
        // immediately so we don't miss any out-of-band StoreKit events
        // (e.g. a purchase completing while the user is mid-relaunch).
        observerTask = Task { [weak self] in
            await self?.observeTransactionUpdates()
        }
        // Initial product load + entitlement refresh are deferred to
        // `initialize()` so callers can await them before deciding
        // whether to show the paywall.
    }

    /// Run the initial product load + entitlement refresh. Awaitable so
    /// the App-level `.task` can wait for entitlements to settle before
    /// deciding whether to auto-present the paywall. Safe to call more
    /// than once — both operations are idempotent.
    func initialize() async {
        await loadProducts()
        await refreshEntitlements()
    }

    // MARK: - Lookups

    /// O(n) but n=3 — fine.
    func product(for tier: EntitlementState.ProTier) -> Product? {
        products.first { $0.id == tier.rawValue }
    }

    // MARK: - Product loading

    func loadProducts() async {
        loadState = .loading
        do {
            let ids = EntitlementState.ProTier.allCases.map(\.rawValue)
            let fetched = try await Product.products(for: ids)

            // Display order: lifetime → yearly → monthly. (Cards visually
            // emphasize lifetime, so it should appear in a prominent slot.)
            let order: [String: Int] = [
                EntitlementState.ProTier.lifetime.rawValue: 0,
                EntitlementState.ProTier.yearly.rawValue:   1,
                EntitlementState.ProTier.monthly.rawValue:  2,
            ]
            products = fetched.sorted { (order[$0.id] ?? 99) < (order[$1.id] ?? 99) }
            loadState = .loaded
        } catch {
            products = []
            loadState = .failed(error)
        }
    }

    // MARK: - Purchase

    /// Initiates a purchase. On success, `refreshEntitlements()` is called
    /// before returning so the paywall can dismiss with `EntitlementState`
    /// already updated.
    func buy(_ product: Product) async throws {
        purchasingProductID = product.id
        defer { purchasingProductID = nil }

        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try verify(verification)
            await refreshEntitlements()
            await transaction.finish()

        case .userCancelled:
            throw PurchaseError.userCancelled

        case .pending:
            // Will be delivered via Transaction.updates if/when approved.
            throw PurchaseError.pending

        @unknown default:
            throw PurchaseError.unknown(
                NSError(domain: "PaywallStore", code: -1)
            )
        }
    }

    // MARK: - Restore (Apple-required)

    /// "Restore Purchases" button calls this. Forces a sync with the App
    /// Store, then re-reads `currentEntitlements` to refresh local state.
    /// Useful when the user has bought on another device, or after a
    /// reinstall, or to recover after a network glitch.
    func restore() async throws {
        isRestoring = true
        defer { isRestoring = false }
        try await AppStore.sync()
        await refreshEntitlements()
    }

    // MARK: - Entitlement refresh

    /// Reads every verified entitlement, picks the strongest active one,
    /// and pushes it into `EntitlementState.shared`. Idempotent and safe to
    /// call from anywhere.
    func refreshEntitlements() async {
        var winning: EntitlementState.ProTier? = nil

        for await result in Transaction.currentEntitlements {
            guard case .verified(let tx) = result else { continue }

            // Skip revoked (refunds) and expired entitlements.
            if let revoked = tx.revocationDate, revoked < Date() { continue }
            if let exp = tx.expirationDate, exp < Date() { continue }

            guard let tier = EntitlementState.ProTier(rawValue: tx.productID) else { continue }

            // Lifetime is the strongest entitlement — short-circuit when seen.
            if tier == .lifetime {
                winning = .lifetime
                break
            }
            // Among subs: prefer yearly over monthly (yearly is "bigger").
            if winning == nil || (winning == .monthly && tier == .yearly) {
                winning = tier
            }
        }

        EntitlementState.shared.update(activeTier: winning)
    }

    // MARK: - Transaction observer (App lifetime)

    /// Listens to `Transaction.updates` forever. Each delivery is verified,
    /// triggers an entitlement refresh, and is then finished. This catches:
    ///   - subscription renewals
    ///   - refunds (revocations)
    ///   - parental-approval Ask-to-Buy completions
    ///   - cross-device purchases that sync down
    ///   - subscription expirations
    private func observeTransactionUpdates() async {
        for await result in Transaction.updates {
            guard case .verified(let tx) = result else { continue }
            await refreshEntitlements()
            await tx.finish()
        }
    }

    // MARK: - Helpers

    private func verify(_ result: VerificationResult<Transaction>) throws -> Transaction {
        switch result {
        case .verified(let tx):
            return tx
        case .unverified:
            throw PurchaseError.verificationFailed
        }
    }
}
