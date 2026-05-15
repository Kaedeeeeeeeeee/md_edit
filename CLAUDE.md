# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Two parallel tracks

This repo contains **two independent implementations** of the same Notion-style markdown editor, sharing only the BlockNote editor logic. Be explicit about which track a change applies to.

| Track | Path | Stack | Distribution target |
|---|---|---|---|
| Tauri | repo root (`src/`, `src-tauri/`) | Tauri 2 + Rust + React 19 + BlockNote in WKWebView | Self-distributed; uses macOS **private APIs** (`macOSPrivateApi: true` + window-vibrancy) for transparent window + frosted sidebar |
| Native Mac | `native-mac/` | SwiftUI + AppKit + WKWebView hosting React/BlockNote | **App Store-eligible** — public APIs only (`.glassEffect()`, real macOS 26 Liquid Glass) |

The native-mac track has its own `web/` sub-project — it is **not** the same React app as the root `src/`. They diverge (e.g., native-mac has `MathBlock.tsx` / KaTeX).

## Commands

### Tauri track (repo root)

```bash
pnpm install
pnpm tauri dev      # dev (Vite on :1420, Rust shell rebuilds on save)
pnpm tauri build    # release .app + dmg → src-tauri/target/release/bundle/macos/
pnpm build          # tsc + vite build only (no Rust)
```

Pinned: Rust toolchain in `src-tauri/rust-toolchain.toml` (1.95+), Node, Xcode CLT.

### Native Mac track

```bash
cd native-mac/web && pnpm install && pnpm build && cd ..   # builds editor → Resources/editor/
xcodegen generate                                          # project.yml → MarktextNext.xcodeproj
xcodebuild -project MarktextNext.xcodeproj -scheme MarktextNext -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build
open "build/Build/Products/Release/Marktext Next.app"
```

Pinned: Xcode 26+, Swift 6, macOS 26 deployment target, XcodeGen (`brew install xcodegen`).

**Editor-only iteration on native-mac:** `cd native-mac/web && pnpm build` writes directly into `native-mac/Resources/editor/`; the next `xcodebuild` picks it up without re-running xcodegen.

There is no test runner or linter wired up in either track.

## Architecture notes

### Tauri track: menu events flow Rust → JS

`src-tauri/src/lib.rs` builds the native macOS menu bar. Menu clicks `emit("menu", id)` to the webview; `src/App.tsx` listens via `listen<string>("menu", ...)` and dispatches to handlers (new / open_file / open_folder / save / save_as / toggle_sidebar / find / settings). Adding a menu item requires both sides: register the `MenuItemBuilder` in Rust **and** add a case in the JS listener.

File I/O goes through `@tauri-apps/plugin-fs` and `@tauri-apps/plugin-dialog` (no custom Rust commands). The sidebar's frosted-glass effect comes from `apply_vibrancy(...NSVisualEffectMaterial::Sidebar...)` in `setup`, which requires `macOSPrivateApi: true` in `tauri.conf.json` — this is what blocks App Store distribution.

### Native Mac track: two scenes + JS bridge

`MarktextNextApp.swift` declares two SwiftUI `Window` scenes:
- `"picker"` — the launch-time workspace picker, `.defaultLaunchBehavior(.presented)`
- `"main"` — the editor, `.defaultLaunchBehavior(.suppressed)` + `.handlesExternalEvents(matching: ["*"])`

The main window is a **singleton** by design (state restoration must not duplicate it, or duplicates race to own the WebView bridge). Window lifecycle / dock-icon reopen / file-open-with routing lives in `AppDelegate.swift`; see commits referencing "Dock-icon click reopens the picker" and "Bring main window back via direct AppKit, not SwiftUI openWindow" for the rationale behind which path is used where.

**JS ↔ Swift bridge** (`EditorWebView.swift` + `native-mac/web/src/EmbeddedEditor.tsx`):
- Swift → JS: `webView.evaluateJavaScript("window.editorBridge.<method>(...)")` for `loadMarkdown`, `resolveUpload`, `rejectUpload`
- JS → Swift: `window.webkit.messageHandlers.editor.postMessage({ type, ... })` for `"ready"`, `"change"` (`markdown`), `"saveImage"` (`requestId`, `base64`, `mime`, `ext`)

**Image paste/drop** uses an RPC-style upload: BlockNote's `uploadFile` ships bytes as base64 to Swift, which writes them to `<workspace>/attachments/<uuid>.<ext>` and calls `resolveUpload(requestId, "attachments/xxx.png")` back. The `uploadFile` returns a **relative** path so markdown stays portable (`![](attachments/xxx.png)` renders on GitHub/VS Code). Requires an open workspace — `saveImageToAttachments` throws otherwise. Pending uploads live in a module-level `pendingUploads` map keyed by `requestId`.

**Load epoch pattern** (`DocumentStore.loadEpoch`): a monotonically incrementing counter bumped only when Swift wants to *push* content into JS (file open, new doc, file deleted). Editor-originated changes do **not** bump it, which prevents the change → reload loop. `EditorWebView.updateNSView` reads `loadEpoch` to register the dependency; the coordinator compares against `lastDispatchedEpoch` and only re-pushes when it changes. If you add a new "reload the editor" path, bump `loadEpoch`. If you add a new "editor told us it changed" path, do **not**.

**Custom URL scheme** (`EditorSchemeHandler.swift`, scheme `marktext-editor://`): serves the bundled Vite output **and** falls back to the active workspace folder for paths that don't exist in the bundle. The fallback is what makes relative `<img src="attachments/foo.png">` work — page is loaded at `marktext-editor://app/index.html`, so `attachments/foo.png` resolves to `marktext-editor://app/attachments/foo.png`; bundle misses, workspace hits. Both lookups confine to their respective roots via a standardized-path containment check. Loading via `file://` would break in the first place because Vite emits `<script type="module" crossorigin>` and module subresources end up with a null origin — WebKit's CORS denies them and the editor stays blank. Custom scheme uses only public WebKit API so the app stays App Store-eligible.

### Editor (shared concept, separate code)

Both tracks use BlockNote 0.50 with markdown round-trip via `editor.tryParseMarkdownToBlocks(md)` and `editor.blocksToMarkdownLossy(editor.document)`. The conversion is **lossy by design** in BlockNote — don't be surprised if exotic markdown doesn't round-trip cleanly.

## When making changes

- Editing the embedded editor for native-mac: changes in `native-mac/web/src/` need `pnpm build` inside `native-mac/web/` (output goes to `native-mac/Resources/editor/`, gitignored). The Tauri root `src/` is a separate React app — editing it does nothing for native-mac.
- Adding a Tauri menu item: update both `src-tauri/src/lib.rs` (Rust menu builder + dispatcher) and `src/App.tsx` (`useEffect` listener switch).
- Adding a Swift workspace/document state field: if the editor needs to react to it by reloading, bump `store.loadEpoch` at the mutation site.
- The native-mac track targets macOS 26 and uses Swift 6 concurrency (`@MainActor`, `nonisolated`). Don't downgrade these without a reason — the `nonisolated` on `WKScriptMessageHandler.userContentController(...)` is required by the protocol.
