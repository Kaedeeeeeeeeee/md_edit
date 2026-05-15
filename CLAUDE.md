# Notation — 项目上下文

> 给后续接手这个项目的 Claude 看的快速上手文档。

## 这是什么

**Notation** 是一款 **macOS 26+ 原生** Markdown 编辑器，目标是把 Notion 那种**块级所见即所得**的编辑体验做成可以上 **App Store** 的 Mac 原生应用。

- 用户拥有的是磁盘上**真实的 `.md` 文件**，不是某种私有数据库
- 编辑器内核是 **BlockNote（基于 ProseMirror）**，提供 `/` 菜单、块拖拽、表格、代码块、任务列表、KaTeX 公式块等
- 外壳是 **Swift + SwiftUI**，享受 macOS 26 Liquid Glass、`NavigationSplitView`、原生菜单栏等

## 定位

| 维度 | 我们 | 区别于 |
|---|---|---|
| 编辑范式 | **块级 WYSIWYG**（Notion 风） | iA Writer / Bear 的"软 WYSIWYG"（保留 Markdown 符号） |
| 存储 | **本地 `.md` 文件**，可被任何工具读写 | Bear / Notion（私有库） |
| 工作流 | **Workspace-first**（IDE 风，配 single-file fallback） | Word / Pages（document-first） |
| 平台 | **macOS 原生**，App Store 目标 | Electron 跨平台编辑器 |
| 体积 | 约 4.4 MB | MarkText (Electron) ~150 MB |

精神原型：**MarkText 的编辑体验 + Xcode 的启动 / 项目管理 + VS Code 的工作区思维**。

## 技术栈

**外壳（native shell）**
- Swift 6.0 + SwiftUI（macOS 26 SDK，Xcode 26.4+）
- XcodeGen 管理 `.xcodeproj`（`project.yml` 是单一来源）
- App Sandbox + `network.client` entitlement（WKWebView 在沙盒下必需）
- 真 Liquid Glass：`NavigationSplitView` 默认开 + 顶部 toolbar 渐变蒙版
- Apple Developer Team ID: `Y4FV6WUU4V`

**编辑器（embedded web）**
- React 19 + Vite 7 + TypeScript
- BlockNote 0.50（核心 + react + mantine UI）
- KaTeX 自定义块（`$$ … $$` 双向 round-trip）
- 通过 `marktext-editor://` 自定义 URL scheme 加载（`file://` + module + crossorigin 会被 WebKit 拒，custom scheme 绕过 CORS）

**桥接**
- Swift → JS: `webView.evaluateJavaScript("window.editorBridge.loadMarkdown(...)")`
- JS → Swift: `window.webkit.messageHandlers.editor.postMessage({...})`
- `loadEpoch: Int` 计数器（pull 模式）避免 push closure 的多窗口竞争

## 仓库结构

```
notation-demo/                   # 项目根（git remote: Kaedeeeeeeeeee/md_edit）
├── CLAUDE.md                         # 本文件
├── README.md                         # 用户向 README（双 track 说明）
│
├── native-mac/                       # ★ 主线，Swift + WKWebView ★
│   ├── project.yml                   # XcodeGen 配置；改完跑 `xcodegen generate`
│   ├── Sources/Notation/
│   │   ├── NotationApp.swift     # @main App scene + commands
│   │   ├── AppDelegate.swift         # AppKit URL 路由 + 直接 NSWindow 操作
│   │   ├── ContentView.swift         # NavigationSplitView 根
│   │   ├── SidebarView.swift         # 自写递归文件树（不用 List+OutlineGroup）
│   │   ├── EditorWebView.swift       # WKWebView + JS 桥
│   │   ├── EditorSchemeHandler.swift # marktext-editor:// scheme handler
│   │   ├── DocumentStore.swift       # 文件状态、dirty、auto-save、文件树
│   │   ├── WorkspacePicker.swift     # 启动选择器（Xcode 风）
│   │   ├── WorkspaceBookmark.swift   # security-scoped bookmarks 持久化
│   │   ├── FolderWatcher.swift       # FSEventStream 外部变更监听
│   │   ├── WindowAccessor.swift      # SwiftUI ↔ NSWindow 桥 + CloseGuard
│   │   ├── DefaultMarkdownHandler.swift  # 首次启动声明为 .md 默认 app
│   │   ├── RecentFiles.swift         # 最近文件
│   │   ├── Settings.swift            # 设置面板
│   │   ├── DebugLog.swift            # 文件日志（绕开 unified log 过滤）
│   │   └── Notation.entitlements # sandbox + user-selected files + network.client
│   ├── Resources/editor/             # Vite build 产物（gitignored，会 bake 进 .app）
│   ├── Assets.xcassets/AppIcon.appiconset/  # 自动生成
│   ├── Icon/AppIcon.svg              # 应用图标源（SVG，可编辑）
│   ├── scripts/build-icon.sh         # SVG → 所有 PNG 尺寸 → Asset Catalog
│   └── web/                          # React + BlockNote 子项目
│       ├── package.json
│       ├── vite.config.ts            # 把 build 直接写到 ../Resources/editor
│       └── src/
│           ├── main.tsx
│           ├── EmbeddedEditor.tsx    # BlockNote + bridge
│           └── MathBlock.tsx         # KaTeX 自定义块
│
└── src/, src-tauri/                  # 最早的 Tauri 版本，保留作参考，已停止迭代
```

## 关键设计决策（踩过的坑）

### 1. 为什么从 Tauri 切到 Swift + WKWebView

最初是 Tauri，10 MB 包体。后来用户决定走 App Store，Tauri 当前栈用到的 `tauri-plugin-liquid-glass` / `macos-private-api` / `window-vibrancy` 私有 API 全被 App Store 否决。Swift + WKWebView 混合是唯一既能用 macOS 26 真 Liquid Glass、又能上架的路。

### 2. 为什么编辑器是 web 而不是 Swift 原生

Notion 风格的块级 WYSIWYG = 自己重写 ProseMirror。AppKit 上做的话约 2-3 年。BlockNote 已经成熟，复用之。**编辑器**永远是 web。

### 3. 自定义 URL scheme（不是 file://）加载编辑器

Vite 默认 `<script type="module" crossorigin>` 在 `file://` 下因为 null-origin + crossorigin 触发 CORS 拒载。注册 `marktext-editor://` 自定义 scheme（`WKURLSchemeHandler`）规避，全公开 API。

### 4. `com.apple.security.network.client` entitlement 必加

沙盒下 WKWebView 的**所有** load（包括 in-bundle / 自定义 scheme）走 networking stack，没这个 entitlement WebKit 直接拒绝、不调任何 delegate、static 失败。这是隐式契约。

### 5. CloseGuard 拦截 windowShouldClose + orderOut

主窗口红色按钮按下不真正关闭，而是 `orderOut` 隐藏。SwiftUI scene 状态、WebView、文件树都保留下来。⌘Q 走 `applicationShouldTerminate`，不经过 `windowShouldClose`，真退出不受影响。

### 6. 文件 URL 路由的 AppKit 直接路径

SwiftUI 的 `.onOpenURL` + `openWindow(id:)` 在 NSWindow 被 `orderOut` 之后进入 ghost 状态，notification + onReceive 不可靠。`AppDelegate` 持显式 NSWindow weak ref（由各 scene 的 `WindowAccessor` 注册），用 AppKit 直接 `makeKeyAndOrderFront` / `orderOut` 操控窗口，绕开 SwiftUI 状态机。

### 7. 自写文件树而非 SwiftUI `List(_, children:, selection:)`

原生 List 强制把选中行染成系统 accent 蓝，文件夹也会被高亮；且整行点击只能选中、不能 toggle 展开。换成 `ScrollView { LazyVStack { ForEach { NodeRow }}}` 自递归后，文件夹无背景态、文件用浅灰、点整行展开/折叠都自定义。

### 8. Editor 同步走 pull 不走 push

DocumentStore 上的 `loadEpoch: Int` 单调递增，编辑器在 `updateNSView` 里读它来决定要不要 reload。`store.loadIntoEditor = closure` 这种 push 模式在多窗口下后写覆盖、状态恢复时还会竞争，已弃用。

## 常用命令

```bash
cd /Users/user/notation-demo/native-mac

# 改了 web/ 之后：
cd web && pnpm build && cd ..

# 改了 project.yml 或加了新 .swift：
xcodegen generate

# 构建 Release .app：
xcodebuild -project Notation.xcodeproj -scheme Notation \
  -configuration Release -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build

# 装到 /Applications + 刷 Launch Services：
rm -rf "/Applications/Notation.app"
cp -R "build/Build/Products/Release/Notation.app" /Applications/
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f -R "/Applications/Notation.app"

# 应用图标改了 Icon/AppIcon.svg 之后：
./scripts/build-icon.sh

# 看运行时日志：
cat "$HOME/Library/Containers/com.notation.app/Data/Documents/mt-debug.log"

# 清状态恢复（如果遇到"上次异常退出"对话框）：
rm -rf "$HOME/Library/Saved Application State/com.notation.app.savedState"
rm -rf "$HOME/Library/Containers/com.notation.app/Data/Library/Saved Application State"
```

## 已知未做（deferred）

- Mermaid 自定义块（同 KaTeX 但更重的 lib，没接）
- 多窗口 / 多 tab
- 文档内 Find & Replace
- 跨文件搜索
- 真代码签名（Team ID 已配但还在用 ad-hoc `-`）
- App Store Connect 提交流程

## 用户偏好（持续观察到的）

- 喜欢"先看到、再决定"。提产品方向时给可选方案让用户选，别擅自押宝
- 视觉上要"原生"，但 hover / 选中态不喜欢实色蓝，偏好浅灰
- 工作区是核心心智，单文件是 fallback
- 长 commit message 受欢迎（"why" + 关键决策点）

## Git / 分发

- Remote: `https://github.com/Kaedeeeeeeeeee/md_edit`
- 用户 GitHub: `Kaedeeeeeeeeee`
- Apple Developer Team ID: `Y4FV6WUU4V`（在 `project.yml`）
- 每次完成一个改动都 commit + push 到 main，commit message 写"为什么"和踩过的坑
