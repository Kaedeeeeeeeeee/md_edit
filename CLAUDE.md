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
| 体积 | 约 10 MB（universal arm64+x86_64） | MarkText (Electron) ~150 MB |

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
md_edit/                              # 项目根（git remote: Kaedeeeeeeeeee/md_edit）
├── CLAUDE.md                         # 本文件
├── README.md                         # 用户向 README
├── PRIVACY.md                        # 隐私政策（与 landing 站 /privacy 同步）
├── docs/                             # GitHub Pages landing（index + /privacy）
│   ├── index.html
│   ├── privacy.html
│   ├── styles.css
│   └── assets/
└── native-mac/                       # Swift + WKWebView 主体
    ├── project.yml                   # XcodeGen 配置；改完跑 `xcodegen generate`
    ├── APP_STORE_SUBMISSION.md       # 上架 checklist
    ├── Sources/Notation/
    │   ├── NotationApp.swift             # @main App scene + commands
    │   ├── AppDelegate.swift             # AppKit URL 路由 + 直接 NSWindow 操作
    │   ├── ContentView.swift             # NavigationSplitView 根 + onboarding 门
    │   ├── AppModel.swift                # 协调层：三个状态层 + workspace 注册表 + openDocument 路由
    │   ├── WorkspaceSession.swift        # 工作区：文件夹、文件树、FSEvents、文件操作、附件
    │   ├── DocumentSession.swift         # 单文档生命周期：内容、dirty、autosave、编码
    │   ├── DocumentWindowManager.swift   # 文档小窗注册表：每窗 session + scope + 待开窗队列
    │   ├── DocumentWindowView.swift      # 文档小窗（纯编辑器、真关闭）+ DocumentCloseGuard
    │   ├── SidebarState.swift            # 侧栏 UI 态：多选、剪贴板、展开集合
    │   ├── SidebarView.swift             # 自写递归文件树（不用 List+OutlineGroup）
    │   ├── SidebarResponder.swift        # 侧栏 AppKit first-responder（Edit 菜单路由）
    │   ├── EditorWebView.swift           # WKWebView + JS 桥
    │   ├── EditorSchemeHandler.swift     # marktext-editor:// scheme handler
    │   ├── OnboardingView.swift          # 首启 onboarding（容器 vault 默认 / iCloud 可选）
    │   ├── WorkspaceBookmark.swift       # workspace bookmark 持久化（当前 + 最近）
    │   ├── DocumentDirBookmarks.swift    # 游离文档所在目录的授权缓存
    │   ├── SecurityScopedBookmark.swift  # bookmark 原语（makeBlob/resolve/peek）
    │   ├── FilePaths.swift               # contains/uniqueURL/isMarkdown 共享 helpers
    │   ├── AlertPrompts.swift            # NSAlert helpers（present/promptForName）
    │   ├── FolderWatcher.swift           # FSEventStream 外部变更监听
    │   ├── WindowAccessor.swift          # SwiftUI ↔ NSWindow 桥 + CloseGuard
    │   ├── DefaultMarkdownHandler.swift  # 首次启动声明为 .md 默认 app
    │   ├── RecentFiles.swift             # 最近文件
    │   ├── MultiFileTransfer.swift       # 侧栏拖拽 Transferable 封装
    │   ├── Settings.swift                # 设置面板（含 AI 隐私 banner）
    │   ├── AIService.swift               # Anthropic + OpenAI 流式客户端（BYO key）
    │   ├── KeychainStore.swift           # API key 存储（macOS Keychain）
    │   ├── Agent/                        # AI 聊天 overlay
    │   ├── Paywall/                      # Pro 订阅 / StoreKit
    │   ├── DebugLog.swift                # 文件日志（绕开 unified log 过滤）
    │   ├── PrivacyInfo.xcprivacy         # Apple 隐私清单（App Store 必需）
    │   └── Notation.entitlements         # sandbox + user-selected files + network.client
    ├── Resources/editor/             # Vite build 产物（gitignored，会 bake 进 .app）
    ├── Assets.xcassets/AppIcon.appiconset/  # 自动生成
    ├── Icon/AppIcon.svg              # 应用图标源（SVG，可编辑）
    ├── scripts/build-icon.sh         # SVG → 所有 PNG 尺寸 → Asset Catalog
    └── web/                          # React + BlockNote 子项目
        ├── package.json
        ├── vite.config.ts            # 把 build 直接写到 ../Resources/editor
        └── src/
            ├── main.tsx
            ├── EmbeddedEditor.tsx        # BlockNote + bridge
            ├── ai/                       # AI 弹窗 / Liquid Glass 侧菜单
            ├── agent/                    # 编辑器 bridge (agent overlay)
            └── MathBlock.tsx             # KaTeX 自定义块
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

DocumentSession 上的 `loadEpoch: Int` 单调递增，编辑器在 `updateNSView` 里读它来决定要不要 reload。`store.loadIntoEditor = closure` 这种 push 模式在多窗口下后写覆盖、状态恢复时还会竞争，已弃用。

### 9. 状态分层（B2 重构阶段 1，2026-07）

原 `DocumentStore` 是约 1000 行的 god object，已拆四层：**AppModel**（协调层 + workspace 注册表 / bookmark 持久化，`@Environment` 里变量名仍叫 `store`）持有 **WorkspaceSession**（文件夹 / 树 / watcher / 全部文件操作 / 附件）、**DocumentSession**（单文档内容 / dirty / autosave，只通过 `workspaceRoot` / `onFileWritten` 两个注入闭包了解工作区）、**SidebarState**（纯侧栏 UI 态）。约定：文件操作返回"实际发生了什么"（move 返回 (from,to) 对、trash 返回真正删掉的 URL），由 AppModel 把后果应用到 document / sidebar。

### 10. 文档小窗 + 按包含关系路由（B2 阶段 2，2026-07）

`AppModel.openDocument(at:heldScope:)` 是"打开一个 md"的唯一入口（Finder 双击 / Open File… / Recents 全走它）：workspace 内 → 主窗 + 侧栏展开选中；workspace 外 → 独立文档小窗（`WindowGroup(id:"document", for: DocumentWindowID.self)`，同 URL 二开自动聚焦既有窗）。杂交态（侧栏是工作区树、编辑器却是外部文件）从此不可达。要点：
- **冷启动竞态**：Finder open 事件可能早于任何 SwiftUI 视图存在，AppKit 又调不到 `openWindow` 环境 action → `DocumentWindowManager` 维护待开窗队列，主 scene 的 `DocumentWindowOpener` 在 onReceive **和** onAppear 双路排空。多文件连开（Finder 多选 Open）时，通知必须 `DispatchQueue.main.async` 延后一个 runloop tick，否则在 AE handler 内同步 post 会赶上 SwiftUI scene 更新、`openWindow` 静默 no-op、值卡在队列里。
- **scope 所有权转移**：`openDocument` 接收已 START 的 security-scoped URL；workspace 文件立刻释放（workspace grant 已覆盖），外部文件交给窗口注册表、关窗时释放。
- **文档小窗真关闭**（`DocumentCloseGuard`，与主窗 orderOut 的 `CloseGuard` 是兄弟变体）；不参与状态恢复（`.restorationBehavior(.disabled)`），重启后重开走 Recents bookmark。
- **RecentFiles 存 security-scoped bookmark**（`RecentFileBookmarks` key），修掉了"重启后工作区外最近文件消失/打不开"的沙盒 bug；渲染用 peek、点击才 resolve 单条。
- **⌘N 不走焦点路由**：新建笔记永远属于工作区（Untitled autosave 需要落点），文档小窗里 ⌘N 会前置主窗。
- 侧栏 reveal 必须插入树扫描产出的同一批 node.url（路径拼出来的 URL 会因结尾斜杠差异 Set 匹配失败）。

### 11. macOS 26 上文档小窗踩的三个 SwiftUI/AppKit 坑（B2 阶段 2 调试）

三个都花了单独的 debug session 定位，日志走 `NOTATION_STDOUT_LOG=1 ./Notation.app/Contents/MacOS/Notation`（容器 log 文件被 TCC 挡，直接终端跑二进制看 stdout 镜像）：

1. **SwiftUI 的 AppDelegate adaptor 会把自己的 wrapper 装成 `NSApp.delegate`**，`NSApp.delegate as? AppDelegate` 在 macOS 26 返回 nil（回调仍转发给我们，但类型转换失败），悄悄打断了所有 AppKit 侧靠这个转换的调用点（窗口注册、showMainWindow、关闭按钮 dirty 圆点）。解法：`AppDelegate` 在 `init` 里把自己存进 `static weak var shared`，全部改走它。
2. **SwiftUI 的文件打开事件路由会 `NSWindow._close` 掉当前呈现的 Window**：外部文件打开时，SwiftUI 的 `AppWindowsController.activateWindowForExternalEvent` 为了给事件找窗口，直接 `_close` 主窗（程序性关闭、**绕过 windowShouldClose**，CloseGuard 拦不到）。解法：`AppDelegate.applicationWillFinishLaunching` 里抢先 `NSAppleEventManager.setEventHandler` 认领 `kAEOpenDocuments`（在 AppKit 装它自己的 handler 之前），事件自己解析 URL 走 `openDocument`，SwiftUI 的 scene 路由再也碰不到。
3. **`WindowGroup(for: URL.self)` 会被文件打开事件的 presentation-type 匹配命中**（触发坑 2）。解法：包一层不透明的 `DocumentWindowID { let url }` 当 presentation type，文档窗口只由我们自己的 `openWindow(id:value:)` 开，事件路由认不出它。

## 常用命令

```bash
cd /Users/user/marktext-next-demo/native-mac

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
cat "$HOME/Library/Containers/com.shifengzhang.notation/Data/Documents/mt-debug.log"

# 清状态恢复（如果遇到"上次异常退出"对话框）：
rm -rf "$HOME/Library/Saved Application State/com.shifengzhang.notation.savedState"
rm -rf "$HOME/Library/Containers/com.shifengzhang.notation/Data/Library/Saved Application State"
```

## 已知未做（deferred）

- Mermaid 自定义块（同 KaTeX 但更重的 lib，没接）
- 多 tab；workspace 多窗（文档小窗已做，见决策 #10）
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
