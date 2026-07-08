# Notation — native-mac

Swift + SwiftUI hybrid build of Notation, targeting **macOS 15+** with
Liquid Glass enabled on macOS 26 when available and the App Store as a
distribution target.

The editor itself (BlockNote / ProseMirror) still runs inside a `WKWebView`,
but everything else — sidebar, toolbar, menu bar, settings, file ops — is
fully native SwiftUI / AppKit using only public APIs.

## Architecture

```
native-mac/
├── project.yml            # XcodeGen config — regenerate the .xcodeproj from this
├── Sources/Notation/
│   ├── NotationApp.swift   # @main App scene + commands + Settings
│   ├── ContentView.swift       # NavigationSplitView root
│   ├── SidebarView.swift       # File tree (OutlineGroup)
│   ├── EditorWebView.swift     # WKWebView host + JS bridge
│   ├── DocumentStore.swift     # File state, dirty tracking, auto-save
│   ├── Settings.swift          # Settings scene (auto-save, theme)
│   ├── RecentFiles.swift       # UserDefaults-backed recents
│   ├── WindowAccessor.swift    # NSWindow delegate for close-confirm
│   └── Notation.entitlements  # App Sandbox + user-selected files
├── Resources/editor/      # Vite build output (gitignored — regenerate from web/)
└── web/                   # Minimal React + BlockNote sub-project
    ├── src/
    │   ├── main.tsx
    │   └── EmbeddedEditor.tsx  # BlockNote + window.editorBridge / postMessage
    └── vite.config.ts          # outDir: ../Resources/editor
```

## Build from clean clone

```bash
# Install web deps + build the embedded editor into Resources/editor/
cd web
pnpm install
pnpm build
cd ..

# Generate Xcode project from project.yml
xcodegen generate

# Build .app
xcodebuild \
  -project Notation.xcodeproj \
  -scheme Notation \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  build

# Launch
open "build/Build/Products/Release/Notation.app"
```

## Iterate on the editor only

Editor changes don’t need a Swift rebuild — re-running the web build
copies updated files straight into the .app the next time xcodebuild
picks up the resources phase:

```bash
cd web && pnpm build && cd ..
xcodebuild ... build
```

## JS ↔ Swift bridge

**Swift → JS**: `webView.evaluateJavaScript("window.editorBridge.loadMarkdown(...)")`
to swap the editor’s document. Triggered from `DocumentStore.loadFile`, etc.

**JS → Swift**: `window.webkit.messageHandlers.editor.postMessage({...})` from
the embedded React app. Two messages:

- `{ type: "ready" }` — editor mounted; coordinator flushes any pending markdown
- `{ type: "change", markdown }` — debounced auto-save logic listens here

## Distribution model

Notation ships as a paid Mac App Store app. There are no StoreKit products,
subscriptions, trials, restore-purchase flows, or Pro entitlements in the
runtime. After purchase, the editor and all AI entry points are available.
AI still requires the user's own provider API key.

Before submission:

- [ ] Confirm App Store Connect pricing is set as a paid app, anchored near CNY ¥68
- [ ] Do not create in-app purchase products
- [ ] Rebuild `web/`, regenerate the Xcode project, then archive with Mac App Store signing
- [ ] Confirm screenshots and metadata describe paid download + BYO API key clearly
- [ ] Verify Release logs do not contain prompts, Markdown content, API keys, or full file paths

## Deferred features (future work)

- KaTeX math blocks (custom BlockNote schema, ~100 lines)
- Mermaid diagram blocks (same pattern, heavier dep)
- Auto-watch file tree for external changes
- Multi-window / multi-tab
- Find & Replace across the document
- Search across folder
