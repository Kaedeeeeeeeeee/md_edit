# Notation — App Store Submission Checklist

Audit done 2026-05-14. Sandbox / entitlements / Keychain / AI disclosure UX are all in shape. This file lists what's left.

---

## 0. State of the codebase (already done — don't redo)

- [x] App Sandbox + Hardened Runtime enabled (`project.yml`)
- [x] Entitlements: app-sandbox, user-selected files RW, app-scope bookmarks, network.client
- [x] Security-scoped bookmark flow (`WorkspaceBookmark.swift`)
- [x] API keys in Keychain (`KeychainStore.swift`), masked in UI
- [x] HTTPS-only AI calls via `URLSession.shared` (no plaintext HTTP anywhere)
- [x] First-key-save disclosure NSAlert (`Settings.swift` → `saveAIKey`)
- [x] No private API usage in Sources/
- [x] No remote URL loads in web/ — editor is fully bundled
- [x] No CDN scripts; KaTeX + BlockNote shipped locally
- [x] `ITSAppUsesNonExemptEncryption: false` declared in Info.plist
- [x] `LSApplicationCategoryType: productivity`
- [x] Bundle ID `com.notation.app`, Team ID `Y4FV6WUU4V`

---

## 1. One-time setup (do once, never again)

### 1.1 App Store Connect
- [ ] Sign in at https://appstoreconnect.apple.com with the Team ID `Y4FV6WUU4V` account
- [ ] My Apps → "+" → New App
  - Platform: macOS
  - Name: `Notation` (must be globally unique — check availability; have fallback like `Notation Editor`)
  - Primary language: English (U.S.)
  - Bundle ID: `com.notation.app` (must be registered in developer.apple.com → Identifiers first)
  - SKU: anything stable, e.g. `notation-mac-001`
  - User access: Full Access
- [ ] App Information
  - Subtitle (30 chars): e.g. "Notion-style Markdown editor"
  - Category: Productivity (primary); Developer Tools (secondary, optional)
  - Content rights: yes/no on third-party content
  - Age rating: complete the questionnaire (likely 4+)

### 1.2 Certificates & provisioning (developer.apple.com → Certificates, Identifiers & Profiles)
- [ ] Create a **Mac App Distribution** certificate (NOT Developer ID — that's for direct distribution)
- [ ] Create a **Mac Installer Distribution** certificate (needed to sign the .pkg uploaded to App Store)
- [ ] Register Bundle ID `com.notation.app` with the App Sandbox capability
- [ ] Create a **Mac App Store provisioning profile** for `com.notation.app`
- [ ] Download both certs into Keychain; install the profile in `~/Library/MobileDevice/Provisioning Profiles/`

Tip: `CODE_SIGN_STYLE: Automatic` in `project.yml` will pull these via Xcode if signed in. But for CI / `xcodebuild` from the command line, manual is more reliable. See section 3.

### 1.3 Privacy Manifest (`PrivacyInfo.xcprivacy`)
Required by Apple since May 2024 for all new App Store apps.

Create `Sources/Notation/PrivacyInfo.xcprivacy` and add it to `project.yml` resources. Minimal content for Notation:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key><false/>
    <key>NSPrivacyTrackingDomains</key>
    <array/>
    <key>NSPrivacyCollectedDataTypes</key>
    <array/>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array><string>CA92.1</string></array>
        </dict>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array><string>C617.1</string></array>
        </dict>
    </array>
</dict>
</plist>
```

The two API reasons are because we read/write UserDefaults (recent files, AI provider, etc.) and stat files (file tree). If we add more (disk space queries, system boot time, etc.), append accordingly. Full reason codes at https://developer.apple.com/documentation/bundleresources/privacy_manifest_files .

---

## 2. Privacy Nutrition Label (App Store Connect → App Privacy)

This is **the most likely source of rejection** — they look at AI features carefully. Be accurate but don't over-declare.

### Data collected
- **"Do you collect data from this app?"** → **Yes** (only because of AI; the editor itself collects nothing)
- For the AI calls, declare under **"Data Linked to You"** = No, **"Data Used to Track You"** = No, **"Data Not Collected"** for everything else.
- The actual data type to declare is **User Content → Other User Content**
  - **Used for**: "App Functionality" only (do NOT check Analytics or Personalization)
  - **Linked to user's identity**: No
  - **Used for tracking**: No
- This represents: when the user invokes Ask AI / Research / image generation, the selected Markdown + their prompt is sent to the third-party AI provider they chose. Apple's stance is that you must declare this even though your servers never see it.
- Also declare **Purchases → Purchase History**:
  - **Used for**: "App Functionality" only
  - **Linked to user's identity**: No
  - **Used for tracking**: No
  - Reasoning: Apple's Privacy Manifest schema requires declaring purchases used by the app even when transactions are handled entirely by StoreKit. The `PrivacyInfo.xcprivacy` in the repo already declares `NSPrivacyCollectedDataTypePurchaseHistory` — mirror that here in the Nutrition Label.

### Third-party SDKs
- None to declare. We don't bundle any analytics, ads, or third-party SDKs.

### Privacy policy URL
- **Required**. Cannot be a `notion.so` page or similar — must be on a domain you control.
- Minimum content: what data the app collects, that AI calls go to user-chosen third parties, link to those providers' policies (anthropic.com/legal/privacy, openai.com/policies/privacy-policy), no analytics, no tracking, contact email.
- Draft sitting in the repo as `PRIVACY.md` is a good idea before deployment.

---

## 3. Build & upload pipeline

### 3.1 Build a signed Release archive

From `native-mac/`:

```bash
# 1. Rebuild the web bundle (Vite → Resources/editor)
cd web && pnpm install && pnpm build && cd ..

# 2. Regenerate the Xcode project
xcodegen generate

# 3. Archive — automatic signing requires being signed in to Xcode
xcodebuild -project Notation.xcodeproj -scheme Notation \
  -configuration Release \
  -archivePath build/Notation.xcarchive \
  archive
```

If automatic signing fights you, switch to manual:
- In `project.yml`: `CODE_SIGN_STYLE: Manual`, add `PROVISIONING_PROFILE_SPECIFIER: <profile name>`, `CODE_SIGN_IDENTITY: "Apple Distribution"`.

### 3.2 Export the .pkg for App Store

```bash
xcodebuild -exportArchive \
  -archivePath build/Notation.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist
```

Where `ExportOptions.plist` is:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>destination</key>
    <string>upload</string>           <!-- or "export" to keep a local .pkg -->
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>Y4FV6WUU4V</string>
</dict>
</plist>
```

Setting `destination` to `upload` makes `xcodebuild` push directly. Otherwise use Transporter.app (download from Mac App Store) and drag the exported `.pkg`.

### 3.3 TestFlight
- After upload, the build appears in App Store Connect → TestFlight (~10–30 min processing)
- Internal Testing: instant, up to 100 testers from your team
- External Testing: needs a quick "Beta App Review" (separate from full submission), but lets you test the App Store install flow

---

## 4. Store listing assets

### 4.1 Screenshots
- **Required sizes**: 1280×800, 1440×900, 2560×1600, 2880×1800 (deliver any one; Apple upscales/downscales)
- Recommended: 6 screenshots showing block editor, slash menu, workspace sidebar, AI chat, AI research, Liquid Glass UI
- No frames, no marketing text overlays (Apple has tightened this in 2025)

### 4.2 App description (4000 char max)
Lead with the value prop, not the tech. Avoid third-party brand names:
- ❌ "Powered by ChatGPT and Claude"
- ✓ "Optional AI assistance — bring your own API key from OpenAI-compatible providers or Anthropic"

### 4.3 Keywords (100 char max, comma-separated, no spaces after commas)
Example: `markdown,editor,notion,notes,writing,wysiwyg,blocks,ai,workspace,productivity`

### 4.4 Promotional text (170 char, can change without re-submission)
Use for current updates: "Now with Research Mode — gather sources and synthesize them in your editor."

---

## 5. Review-prone surfaces to harden

Apple's reviewers don't read code — they run the app. Make sure these paths can't crash on a clean install:

- [ ] Launching with **no recent files / no recent folders** → picker should show empty state cleanly
- [ ] Opening an .md file from **Finder before** the app has ever opened a workspace
- [ ] Picking a folder, **revoking its bookmark** (e.g. deleting it from disk), relaunching → should not crash; should fall back to picker
- [ ] Saving an AI key with **disclosure alert dismissed via "Cancel"** → key should NOT be saved
- [ ] Calling Ask AI with **no key** → "No API key set. Open Settings → AI." (already implemented; verify it actually shows)
- [ ] Calling Research with **OpenAI provider** → graceful refusal message (already implemented; verify)
- [ ] Calling Image Gen with **Anthropic provider** → graceful refusal message (already implemented; verify)
- [ ] **Airplane mode + AI request** → network error surfaced, no hang
- [ ] **AI server returns 401** (bad key) → readable error, not the raw JSON

### AI disclosure UX — one improvement worth making before review

Current behaviour: NSAlert fires when **saving** the first key. By that point the user has already entered the key.

Reviewers prefer disclosure **before** the user invests effort. Consider moving the disclosure to the **first time** the AI tab is opened — or putting a visible, non-dismissible info banner at the top of the AI tab that explains "Your selected text and instructions will be sent to your chosen provider over HTTPS."

The current footer text under the Provider section ("Your selected text and prompts will be sent...") already does most of this work. The banner just makes it more prominent.

---

## 6. Things to remove / clean up before first submission

- [ ] **Tauri root** (`src/`, `src-tauri/`, `index.html`, root `package.json`, `tauri.conf.json`): this code is not shipped in the App Store binary, but `tauri.conf.json` has `macOSPrivateApi: true`. If anyone clones the repo and accidentally `tauri build`s a binary, that build cannot ship. **Recommendation**: either delete the Tauri tree or add a top-level README warning. Doesn't block submission, but a hygiene item.
- [ ] `mt-debug.log` writing (`DebugLog.swift`) — check it doesn't log API key fragments or user content. Quick `grep` after the next test run.
- [ ] Any `print(...)` statements left in Swift code — these go to Console.app; not a security issue but noisy.
- [ ] **Copyright string** in `project.yml` is currently the placeholder `© 2026 Notation`. Update to legal entity / your name before submitting.

---

## 7. Submission flow (the actual day)

1. Bump `CFBundleVersion` in `project.yml` (must be unique per upload)
2. `cd web && pnpm build && cd ..` → `xcodegen generate` → archive + upload (see §3)
3. App Store Connect → My Apps → Notation → macOS App → "+" version → fill in:
   - What's New (release notes, per-locale)
   - Build picker → select the uploaded build
   - Screenshots if changed
   - Save → Submit for Review
4. Set **Manual Release** the first few times so you can pull the trigger after approval, in case anything looks wrong in production.

Review SLA: 24–48h typical for macOS in 2026. Rejections come back as "Resolution Center" messages; reply in the same thread.

---

## 8. Realistic timeline

| Step | Time |
|---|---|
| Cert + profile + ASC app record | 30–60 min if no friction |
| Privacy manifest + privacy policy page | 1–2 hours |
| Screenshots + description + keywords | 2–3 hours |
| First build + upload + TestFlight smoke test | 1 hour |
| First Apple review | 24–48h |
| Likely 1 rejection round (Privacy Label nuance, edge-case crash) | + 24–48h |

So plan **~1 week** between "I want to ship" and "it's on the store" if nothing goes wrong, two if the first review pushes back.
