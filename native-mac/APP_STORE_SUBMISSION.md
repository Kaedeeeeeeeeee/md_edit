# Notation — Paid App Store Submission Checklist

Updated 2026-07-08 for the paid-upfront `1.0` launch.

Notation is now a paid Mac App Store app. There are no in-app purchases,
subscriptions, trials, restore-purchase flows, accounts, analytics,
crash-reporting SDKs, or Notation-run servers. After purchase, the editor and
all AI entry points are available. AI remains bring-your-own-key: selected
content and instructions are sent directly from the user's Mac to their chosen
third-party provider.

---

## 0. Codebase state

- [x] Bundle ID: `com.shifengzhang.notation`
- [x] Team ID: `Y4FV6WUU4V`
- [x] Version: `1.0`
- [x] App Sandbox enabled
- [x] Entitlements: user-selected files read/write, app-scope bookmarks, `network.client`
- [x] Security-scoped bookmarks for workspaces
- [x] API keys stored in macOS Keychain
- [x] Embedded editor is fully bundled; no CDN scripts
- [x] `PrivacyInfo.xcprivacy` included in app resources
- [x] No StoreKit runtime path or `.storekit` scheme configuration
- [x] Release logging disabled by default and redacted when explicitly enabled

---

## 1. App Store Connect setup

Create or confirm the macOS app record:

- Platform: macOS
- Name: `Notation`
- Bundle ID: `com.shifengzhang.notation`
- SKU: `notation-mac-001` or another stable internal SKU
- Primary category: Productivity
- Secondary category: Developer Tools, if desired
- Content rights: answer according to the final screenshots and demo content
- Release type: Manual Release for the first public launch

Paid app setup:

- Confirm the Paid Apps Agreement is active for Team `Y4FV6WUU4V`
- Set the app as a paid app, not a free app
- Keep the existing one-time price schedule; storefronts display Apple's local equivalent
- Exclude China mainland from App Availability while the app contains generative-AI provider integrations that are not licensed there
- Do not create in-app purchase products
- Do not configure subscriptions, introductory offers, trials, promo offers, or consumables

Public URLs:

- Privacy Policy URL: `https://kaedeeeeeeeeee.github.io/md_edit/privacy.html`
- Support URL: `https://github.com/Kaedeeeeeeeeee/md_edit/issues`
- Marketing URL: `https://kaedeeeeeeeeee.github.io/md_edit/`

---

## 2. App Privacy answers

Use Apple's App Privacy form, not only `PrivacyInfo.xcprivacy`.

Declare AI third-party processing:

- Data type: User Content -> Other User Content
- Purpose: App Functionality
- Linked to user: No
- Used for tracking: No

This represents user-initiated Ask AI, Research, and Image Generation calls
where selected text and the user's instruction are sent directly to the
configured third-party provider.

Do not declare:

- Purchase History, because the app no longer reads StoreKit transactions
- Contact Info, Identifiers, Usage Data, Diagnostics, Analytics, Advertising Data, or tracking
- Third-party SDK data collection

Keep `PrivacyInfo.xcprivacy`, `PRIVACY.md`, and `docs/privacy.html` aligned:

- Notation itself does not collect user data
- Files remain local unless the user explicitly invokes AI
- API keys are stored in Keychain and never sent to Notation
- No subscriptions or in-app purchases exist

---

## 3. Build and upload

From `native-mac/`:

```bash
cd web && pnpm install && pnpm build && cd ..
xcodegen generate
xcodebuild -project Notation.xcodeproj -scheme Notation \
  -configuration Release \
  -archivePath build/Notation.xcarchive \
  archive
```

Export or upload with App Store signing:

```bash
xcodebuild -exportArchive \
  -archivePath build/Notation.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist
```

Suggested `ExportOptions.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>Y4FV6WUU4V</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
```

Use Transporter.app or change `destination` to `upload` when credentials are
ready. Each upload must have a unique `CFBundleVersion`.

---

## 4. Store metadata

Screenshots should cover:

- Workspace sidebar and real `.md` files
- Block-level WYSIWYG editing
- Slash menu
- Code, math, task, and table blocks
- AI settings with bring-your-own-key disclosure
- AI usage flow with selected text, without showing real private content

Copy guardrails:

- Say "paid download", "one-time purchase", or "buy once"
- Say AI features are included in the app but require the user's own API key
- Do not say free, Pro, upgrade, restore purchases, subscription, trial, or in-app purchase
- Avoid implying Notation provides hosted AI credits or a server-side AI account
- Describe Notation on its own merits; do not position it as a clone or replacement for a named competitor

Keywords example:

`markdown,editor,notes,writing,wysiwyg,blocks,ai,workspace,productivity`

---

## 5. TestFlight smoke test

Install the processed TestFlight build and verify:

- First launch with no recents
- Open workspace folder
- Open single `.md` file from Finder while app is cold
- Save and auto-save
- Paste image into a document
- External file change refreshes cleanly
- Red close button hides the main window; Dock reopen restores it
- Quit with dirty document prompts correctly
- No Upgrade, Restore Purchases, Manage Subscription, Pro, or paywall UI appears

AI paths:

- No key -> readable "API key required" error
- Bad key -> readable 401/auth error
- Offline -> readable network error
- Anthropic Ask AI
- Anthropic Research
- OpenAI-compatible Ask AI
- OpenAI image generation
- Provider mismatch -> readable capability error

Privacy/logging:

- In Release, `mt-debug.log` should not be created by default
- If `NOTATION_RELEASE_LOG=1` is used for diagnostics, verify the log contains no API key, prompt/query, Markdown content, or full file path

---

## 6. Submission day

1. Bump `CFBundleVersion` in `project.yml`.
2. Rebuild web assets and regenerate the Xcode project.
3. Archive and upload/export the signed App Store build.
4. Wait for App Store Connect processing.
5. Run internal TestFlight smoke test.
6. Attach the build to version `1.0`.
7. Confirm paid-app pricing, privacy answers, screenshots, support URL, and privacy URL.
8. Submit for Review with Manual Release selected.

Review notes should mention:

- Notation is a paid upfront Mac app with no IAP.
- Include a dedicated, review-only AI provider API key and exact test steps. Never ask App Review to supply its own key.
- No account is required.
- User files are local `.md` files selected through macOS file/folder pickers.
- China mainland is excluded from App Availability because the current build exposes third-party generative-AI integrations.
- Explain that BlockNote is used as the open-source editor engine, while Notation's native workspace, disk-file lifecycle, sandbox bookmarks, source mode, math round-trip, external-change handling, and macOS window/menu behavior are product-specific implementations.

Use `APP_REVIEW_RESPONSE.md` as the source for the final reply and review notes.
