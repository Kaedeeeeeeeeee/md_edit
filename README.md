# Notation

A Notion-style block-level Markdown editor for macOS. Real `.md` files on
disk, not a private database. **Coming to the Mac App Store.**

→ Landing page: <https://kaedeeeeeeeeee.github.io/md_edit/>

## Highlights

- Block-level WYSIWYG editing (slash menu, drag handles, code / math / task blocks)
- Workspace-first sidebar like an IDE; single-file open as fallback
- Swift + SwiftUI shell with an embedded BlockNote editor in WKWebView
- Real macOS 26 Liquid Glass — public APIs only, App Store eligible
- Optional AI features (Ask AI, Research, Image Generation) — bring your own API key

## Build

Requires Xcode 26+, XcodeGen (`brew install xcodegen`), Node, pnpm.

```bash
cd native-mac
(cd web && pnpm install && pnpm build)
xcodegen generate
xcodebuild -project Notation.xcodeproj -scheme Notation -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build
open "build/Build/Products/Release/Notation.app"
```

## More

- [native-mac/](native-mac/) — source
- [CLAUDE.md](CLAUDE.md) — architecture and design decisions
- [native-mac/APP_STORE_SUBMISSION.md](native-mac/APP_STORE_SUBMISSION.md) — App Store submission checklist
- [PRIVACY.md](PRIVACY.md) — privacy policy
