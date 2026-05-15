import SwiftUI
import StoreKit

/// The upgrade-to-Pro sheet. Presented in two situations:
///   1. Cold launch when not Pro and outside the 24h cooldown
///      (see `PaywallTrigger.shouldShowOnLaunch()`).
///   2. Any time `.proPaywallRequested` notification fires — i.e., the user
///      attempted an AI feature that requires Pro.
///
/// Reads `PaywallStore` and `EntitlementState` from the SwiftUI environment;
/// `NotationApp` injects both at the scene root.
struct PaywallView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(PaywallStore.self) private var store
    @Environment(EntitlementState.self) private var entitlement

    @State private var lastError: PaywallStore.PurchaseError? = nil
    @State private var didSucceed: Bool = false

    /// Display order, left-to-right. Lifetime sits at the right so the
    /// "最划算" featured card is the obvious endpoint of the user's gaze.
    private let visualOrder: [EntitlementState.ProTier] = [.monthly, .yearly, .lifetime]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 28)

            ZStack {
                if didSucceed {
                    successView
                        .transition(.opacity)
                } else {
                    contentSwitch
                }
            }
            .frame(minHeight: 320)

            disclosureBlock
                .padding(.top, 22)

            footer
                .padding(.top, 14)
        }
        .padding(32)
        .frame(width: 780)
        .background(Color(NSColor.windowBackgroundColor))
        .onChange(of: entitlement.isPro) { _, newValue in
            // When a purchase or restore lands while the sheet is open,
            // flash a success state for ~900ms then dismiss. Same flow for
            // any path that flips isPro — purchase, restore, or family-share
            // arriving from another device.
            if newValue && !didSucceed {
                withAnimation(.easeInOut(duration: 0.25)) {
                    didSucceed = true
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(900))
                    dismiss()
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("升级 Notation Pro")
                    .font(.system(size: 28, weight: .semibold))
                Text("解锁 Ask AI、Research、Image Generation 等全部 AI 功能。")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                PaywallTrigger.recordDismissal()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Main switch (loading / loaded / error / success)

    @ViewBuilder
    private var contentSwitch: some View {
        switch store.loadState {
        case .idle, .loading:
            loadingView
        case .loaded:
            tierGrid
        case .failed:
            errorLoadingView
        }
    }

    // MARK: - Tier grid

    private var tierGrid: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(visualOrder, id: \.self) { tier in
                if let product = store.product(for: tier) {
                    tierCard(for: tier, product: product)
                }
            }
        }
    }

    @ViewBuilder
    private func tierCard(for tier: EntitlementState.ProTier, product: Product) -> some View {
        let isFeatured = (tier == .lifetime)
        let isPurchasing = (store.purchasingProductID == product.id)
        let othersDisabled = (store.purchasingProductID != nil && !isPurchasing)

        VStack(alignment: .leading, spacing: 14) {
            // Top row: tier name + badge for lifetime
            HStack {
                Text(tier.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(isFeatured ? Color.accentColor : .secondary)
                Spacer()
                if isFeatured {
                    Text("最划算")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Color.accentColor, in: Capsule())
                }
            }

            // Price
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(product.displayPrice)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                Text(periodLabel(for: tier))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            // Features
            VStack(alignment: .leading, spacing: 6) {
                ForEach(features(for: tier), id: \.self) { feat in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 12, alignment: .leading)
                        Text(feat)
                            .font(.system(size: 13))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 4)

            // CTA
            Button {
                Task { await buy(product) }
            } label: {
                HStack(spacing: 6) {
                    if isPurchasing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(isFeatured ? .white : .primary)
                    } else {
                        Text(isFeatured ? "买断" : "订阅")
                            .font(.system(size: 14, weight: .medium))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    isFeatured ? Color.accentColor : Color(NSColor.controlColor),
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .foregroundStyle(isFeatured ? .white : .primary)
            }
            .buttonStyle(.plain)
            .disabled(isPurchasing || othersDisabled)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isFeatured ? Color.accentColor.opacity(0.04) : Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    isFeatured ? Color.accentColor : Color.primary.opacity(0.08),
                    lineWidth: isFeatured ? 1.3 : 0.5
                )
        )
        .shadow(
            color: isFeatured ? Color.accentColor.opacity(0.18) : Color.black.opacity(0.04),
            radius: isFeatured ? 14 : 4,
            x: 0,
            y: isFeatured ? 6 : 2
        )
    }

    // MARK: - Feature lists and period labels

    private func features(for tier: EntitlementState.ProTier) -> [String] {
        switch tier {
        case .monthly:
            return ["解锁全部 AI 功能", "随时可在 App Store 取消"]
        case .yearly:
            return ["解锁全部 AI 功能", "约合每月 ¥4.2", "比月订便宜 86%"]
        case .lifetime:
            return ["解锁全部 AI 功能", "所有未来版本免费", "约 1.5 年订阅就回本"]
        }
    }

    private func periodLabel(for tier: EntitlementState.ProTier) -> String {
        switch tier {
        case .monthly:  return "/月"
        case .yearly:   return "/年"
        case .lifetime: return " 一次"
        }
    }

    // MARK: - Other states (loading / error / success)

    private var loadingView: some View {
        HStack {
            Spacer()
            VStack(spacing: 12) {
                ProgressView()
                Text("正在加载商品…")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            Spacer()
        }
    }

    private var errorLoadingView: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("商品加载失败")
                .font(.headline)
            Text("请检查网络连接，然后重试。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("重试") {
                Task { await store.loadProducts() }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var successView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("升级成功")
                .font(.system(size: 22, weight: .semibold))
            Text("所有 AI 功能已解锁。")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Disclosure block (Apple-required)

    private var disclosureBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("订阅在到期前 24 小时内自动续费。可随时在 App Store 设置中取消，终身买断不会扣费。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                Link("用户协议（EULA）",
                     destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Link("隐私政策",
                     destination: URL(string: "https://kaedeeeeeeeeee.github.io/md_edit/privacy.html")!)

                if let err = lastError {
                    Spacer()
                    Text(err.localizedDescription)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 11))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                Task { await restore() }
            } label: {
                HStack(spacing: 6) {
                    if store.isRestoring {
                        ProgressView().controlSize(.mini)
                    }
                    Text("恢复购买")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(store.isRestoring)

            Spacer()

            Button("先用着，下次再说") {
                PaywallTrigger.recordDismissal()
                dismiss()
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(Color(NSColor.controlColor), in: RoundedRectangle(cornerRadius: 8))
        }
        .font(.system(size: 13))
    }

    // MARK: - Actions

    @MainActor
    private func buy(_ product: Product) async {
        lastError = nil
        do {
            try await store.buy(product)
            // Success → entitlement.isPro flips → onChange handles dismissal.
        } catch let err as PaywallStore.PurchaseError {
            if case .userCancelled = err {
                // User backed out of Apple ID prompt — silent.
                return
            }
            lastError = err
        } catch {
            lastError = .unknown(error)
        }
    }

    @MainActor
    private func restore() async {
        lastError = nil
        do {
            try await store.restore()
            // If restore unlocked Pro, onChange handles dismissal.
        } catch {
            lastError = .unknown(error)
        }
    }
}
