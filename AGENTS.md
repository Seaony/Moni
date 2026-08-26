# AGENTS.md

## 项目概览

- Moni 是使用 SwiftUI 与 AppKit 开发的 macOS 菜单栏应用，入口位于 `Moni/MoniApp.swift`。
- 工程文件为 `Moni.xcodeproj`，当前只有 `Moni` 一个 Target 和 Scheme。
- 当前 Swift 版本为 5.0，最低系统版本由工程中的 `MACOSX_DEPLOYMENT_TARGET` 定义。
- Swift Package 依赖包括 Sparkle 和 SweetCookieKit。
- `Moni/Models` 存放数据模型与偏好键，`Moni/Services` 存放采样和系统服务，`Moni/Views` 存放页面，`Moni/Views/Components` 存放共用组件。
- 发布流程以 `docs/RELEASING.md` 为准，不得手工修改生成的 appcast。

## 修改原则

- 修改前先搜索并完整阅读最相近的现有实现，复用现有组件、颜色、动画、布局和状态管理方式。
- 只修改当前需求直接涉及的代码；禁止顺手重构、格式化无关文件或增加未要求的机制。
- 涉及首页卡片时，优先复用 `DashboardGrid.swift`、`SummaryView.swift` 和 `Motion.swift` 中的布局与动画基线。
- 保留现有 `PreferenceKey`、`UserDefaults` 和 `@AppStorage` 的持久化兼容性；需要改变已保存数据结构时必须明确处理迁移。
- 不得把密钥、令牌、证书、签名材料或本机凭据写入仓库。
- 未经用户在当前任务中明确允许，不得 commit、push、创建分支或使用 Git worktree。
- 未经用户明确允许，不得使用浏览器控制或 Computer Use 做界面操作和视觉验收。

## 构建与验证

- 当前工程没有测试 Target。代码修改后至少执行差异检查和 Debug 构建：

```bash
git diff --check
xcodebuild -project Moni.xcodeproj -scheme Moni -configuration Debug -derivedDataPath "$PWD/DerivedData" build
```

- 若后续加入测试 Target，应同时运行与改动相关的测试。
- 构建失败时必须保留当前运行实例，并先报告或修复构建错误，不得启动失败或过期的产物。

## 运行最新版

- 每次完成代码修改并验证构建成功后，必须关闭所有正在运行的旧 Moni 实例，再启动刚构建的 `$PWD/DerivedData/Build/Products/Debug/Moni.app`。
- 终止进程前必须先通过完整可执行文件路径确认 PID，只关闭 Moni 实例，不得使用会误伤其他应用的宽泛进程匹配。
- 启动后再次检查进程列表，确保只运行一个来自项目内 Debug 构建目录的 Moni 实例，便于用户直接验收最新效果。
- 仅文档变更不要求重新构建或重启应用。
