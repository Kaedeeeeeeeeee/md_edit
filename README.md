# Notation

A Notion-style markdown editor for macOS. The active product is the
native-mac build (**Notation**); the Tauri prototype is preserved as
historical reference.

| Track | Path | Stack | Distribution | Status |
|---|---|---|---|---|
| **Tauri prototype** (legacy, frozen) | `./` (root) | Tauri 2 + Rust shell + React/BlockNote in WKWebView | Self-distributed (uses macOS private APIs for transparent window + frosted-glass sidebar) | working, ~10 MB, originally branded "Marktext Next" |
| **Notation** (active, App Store target) | [`native-mac/`](native-mac/) | Swift + SwiftUI + WKWebView for editor | App Store eligible (public APIs only, real macOS 26 Liquid Glass) | working, ~2.7 MB |

Both ship the same BlockNote editor for content (slash menu, drag handles,
block transforms, markdown round-trip via `tryParseMarkdownToBlocks` /
`blocksToMarkdownLossy`).

## Quick start

### Tauri track

```bash
pnpm install
pnpm tauri dev          # development
pnpm tauri build        # release .app + dmg
```

Output: `src-tauri/target/release/bundle/macos/Marktext-Next-Demo.app`

Requires Node, Rust 1.95+ (pinned in `src-tauri/rust-toolchain.toml`), and Xcode CLT.

### Notation (native Mac track)

See [native-mac/README.md](native-mac/README.md) for the full build chain.

```bash
cd native-mac/web && pnpm install && pnpm build && cd ..
xcodegen generate
xcodebuild -project Notation.xcodeproj -scheme Notation -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build
open "build/Build/Products/Release/Notation.app"
```

Requires Xcode 26+, XcodeGen (`brew install xcodegen`), Node, pnpm.

## Why two tracks?

The Tauri version ships in 10 MB and was the first working prototype, but
the macOS 26 Liquid Glass effect and several visual polish features rely
on private Apple APIs that block App Store approval. The native-mac
version uses only public SwiftUI APIs (`.glassEffect()`, `NavigationSplitView`,
real `NSOutlineView`) so it can ship through the App Store, and it ends
up smaller because there’s no embedded Rust runtime.

The editor logic stays in web land in both — that part is irreducible
without rewriting ProseMirror in Swift, which is roughly a 2-year project.
