<div align="center">
  <img src="Moni/Assets.xcassets/AppIcon.appiconset/AppIcon-128@2x.png" width="128" height="128" alt="Moni 图标">
  <h1>Moni</h1>
  <p>一眼看清 Mac 状态、模型用量与本地开发环境。</p>
  <p>
    <a href="https://github.com/Seaony/Moni/actions/workflows/build.yml"><img alt="Build" src="https://img.shields.io/github/actions/workflow/status/Seaony/Moni/build.yml?branch=master&amp;style=flat-square&amp;label=build"></a>
    <a href="https://github.com/Seaony/Moni/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/Seaony/Moni?display_name=tag&amp;style=flat-square"></a>
    <img alt="macOS 26.5+" src="https://img.shields.io/badge/macOS-26.5%2B-111111?style=flat-square&amp;logo=apple">
    <img alt="Swift 5" src="https://img.shields.io/badge/Swift-5-F05138?style=flat-square&amp;logo=swift&amp;logoColor=white">
  </p>
</div>

Moni 是一款使用 SwiftUI 与 AppKit 构建的 macOS 菜单栏监控应用。它把系统状态、进程、网络、存储、Docker 与本地模型用量收进一个紧凑、可定制的弹出窗口，并提供详情页、菜单栏指标与 macOS 小组件。

## 功能亮点

- **完整系统概览**：主机、CPU、内存、GPU、网络、存储、进程、电池、温度、风扇与功耗。
- **模型用量汇总**：从受支持客户端的本地记录中汇总 token、请求、缓存与费用估算，并展示可取得的周期额度和重置时间。
- **可交互图表**：首页与详情页图表支持悬停定位和数值说明，历史范围会随页面选项变化。
- **自由编排首页**：卡片支持拖拽排序和尺寸调整，布局与显示模块会持久保存。
- **自定义菜单栏**：可组合 CPU、内存、网络、磁盘、电池、温度和模型用量，并选择数值、图表或图表加数值。
- **macOS 小组件**：提供小、中、大尺寸的系统概览、资源、网络、存储、进程、Docker 与模型用量组件。
- **贴合系统体验**：支持 System、Dark、Light 三种外观，支持英文与简体中文，并可调整整个弹出窗口的缩放比例。
- **本地优先采样**：系统数据复用统一快照；昂贵采样按页面可见性降频或暂停，模型记录采用缓存与增量读取。

## 安装

从 [最新版本](https://github.com/Seaony/Moni/releases/latest) 下载 DMG，将 `Moni.app` 拖入 Applications 后启动。

当前公开下载包为未使用 Apple Developer ID 签名、未经过 Apple 公证的构建。首次打开时，如果 macOS 阻止运行，请前往 **系统设置 → 隐私与安全性**，确认打开 Moni。

发布包同时支持 Apple silicon 与 Intel Mac，最低系统版本为 macOS 26.5。

## 使用方式

1. 从菜单栏打开 Moni，首页会显示已启用的监控卡片。
2. 使用顶部图标进入各项详情；悬停图表或关键数值可查看解释和精确数据。
3. 打开 Settings，可调整语言、主题、采样间隔、窗口缩放、菜单栏项目、告警、模型来源和首页模块。
4. 在 macOS 小组件图库中搜索 Moni，将需要的组件添加到桌面或通知中心。

> 模型费用按照本地 token 记录与公开 API 标价估算，不代表订阅账单。订阅额度依赖提供商当前可用的数据接口，获取失败时会保留近期有效缓存或显示未知状态。

## 数据与隐私

Moni 的系统指标直接在本机采样，模型用量主要读取本地客户端记录。部分可选信息需要访问外部服务，例如公网 IP 查询、软件更新和提供商额度查询；这些请求失败不会阻断基础系统监控。

每项数据的来源、口径、稳定性与采样频率都记录在 [数据源审计清单](docs/DATA_SOURCE_AUDIT.md) 中。

## 从源码构建

准备 Xcode 26.6，然后运行：

```bash
git clone https://github.com/Seaony/Moni.git
cd Moni
xcodebuild \
  -project Moni.xcodeproj \
  -scheme Moni \
  -configuration Debug \
  -derivedDataPath "$PWD/DerivedData" \
  build
open DerivedData/Build/Products/Debug/Moni.app
```

项目包含以下主要目录：

```text
Moni/          macOS 应用、页面、数据模型与采样服务
MoniWidgets/   WidgetKit 小组件
Shared/        应用与小组件共享的数据结构和本地化能力
scripts/       构建验证与发布脚本
docs/          数据源审计与发布说明
```

## 发布

未配置 Developer ID 与 Apple 公证凭据时，可从干净且已推送的 `master` 发布未签名版本：

```bash
scripts/publish-unsigned-release.sh 1.2.3
```

脚本会构建通用应用、生成 ZIP/DMG、签名 Sparkle appcast、创建版本标签并发布 GitHub Release。完整前置条件和签名发布流程请阅读 [发布说明](docs/RELEASING.md)。

## 技术栈

- Swift 5、SwiftUI、AppKit、WidgetKit
- Sparkle 应用内更新
- Core Graphics、Core WLAN、SystemConfiguration、Metal、IOKit 与 Darwin 系统接口
- GitHub Actions 构建与发布

---

<div align="center">
  <sub>让重要指标留在视线里，而不是藏在十几个系统面板中。</sub>
</div>
