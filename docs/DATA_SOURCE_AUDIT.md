# Moni 数据源审计清单

审计日期：2026-08-27

本清单覆盖首页、全部详情页、菜单栏和 macOS 小组件当前会展示的数值。重复展示的数据只审计一次；菜单栏和小组件均复用同一份 `SystemSnapshot` / `WidgetSystemSnapshot`，没有另行采样。

## 评级

- **A — 官方公开接口**：有平台或提供商公开文档，当前方案适合继续使用。
- **B — 系统接口或官方工具**：来自系统头文件、系统命令或正式产品接口，但缺少高层 SDK 契约。
- **C — 私有或未文档化接口**：系统能提供数据，但键名或格式可能随系统版本变化；没有语义相同的公开替代品。
- **D — 推导值**：由 A/B/C 数据计算而来，准确性取决于输入与定义。
- **E — 本地产品日志**：来自各客户端本地日志；日志格式不是公开稳定 API。
- **F — 未公开网络接口**：可用但不属于公开开发者 API，必须允许失败并保留缓存。

## 1. 主机与系统

| 数据 | 当前来源 | 评级 | 核对结论 |
| --- | --- | --- | --- |
| 电脑名称 | `SCDynamicStoreCopyComputerName` | A | 对应系统“电脑名称”，优于 DNS host name。 |
| 机型标识 | `sysctl hw.model` | B | 返回 Apple 机型标识，如 `Mac15,8`；系统本地查询是合理方案。 |
| 芯片名称 | `sysctl machdep.cpu.brand_string` | B | 返回处理器品牌字符串；显示层再移除重复的 `Apple` 前缀。 |
| macOS 版本 | `ProcessInfo.operatingSystemVersionString` | A | 官方公开接口，继续使用。 |
| Darwin 内核版本 | `uname` | B | POSIX 系统接口，继续使用。 |
| 逻辑 CPU 数 | `ProcessInfo.processorCount` | A | 官方公开接口，继续使用。 |
| 开机时长 | `ProcessInfo.systemUptime` | A | 官方公开接口；为单调系统运行时长。 |
| 1/5/15 分钟负载 | `getloadavg` | B | 标准系统负载平均值，不是 CPU 百分比；现有 tooltip 应维持该解释。 |
| 进程总数 | 成功读取的 `proc_listallpids` 结果数 | D | 是“Moni 当前可读取的进程数”，权限受限进程可能不完整。 |
| 内存容量 | `ProcessInfo.physicalMemory` | A | 官方公开接口。 |
| 存储容量 | 根卷 `URLResourceValues.volumeTotalCapacity` | A | 官方公开接口。 |
| 屏幕物理尺寸 | `CGDisplayScreenSize` 的毫米对角线换算 | A/D | 公开接口；显示器未提供物理尺寸时可能为空，不能用像素分辨率冒充英寸。 |
| 屏幕像素分辨率 | `CGDisplayCopyDisplayMode` 的 `pixelWidth/pixelHeight` | A | 已从 `system_profiler` 私有 JSON 字段切换到 Core Graphics 公开接口。 |
| 屏幕刷新率 | `CGDisplayMode.refreshRate` | A | 已从字符串解析切换到 Core Graphics 公开接口；系统返回 0 时显示未知。 |

官方依据：[ProcessInfo](https://developer.apple.com/documentation/foundation/processinfo)、[CGDisplayMode](https://developer.apple.com/documentation/coregraphics/cgdisplaymode)、[CGDisplayScreenSize](https://developer.apple.com/documentation/coregraphics/cgdisplayscreensize%28_%3A%29)。

## 2. CPU

| 数据 | 当前来源 | 评级 | 核对结论 |
| --- | --- | --- | --- |
| 总占用率 | 两次 `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` tick 差值 | A/D | 官方 Mach 接口；首个样本没有区间差值，显示 0 是正确的未知期处理。 |
| User | user tick 差值 / 总 tick 差值 | A/D | 定义正确。 |
| System | system tick 差值 / 总 tick 差值 | A/D | 定义正确。 |
| Nice | nice tick 差值 / 总 tick 差值 | A/D | 定义正确。 |
| Idle | idle tick 差值 / 总 tick 差值 | A/D | 定义正确。 |
| 每核心占用 | 每个处理器的非 idle tick 差值 | A/D | 与总占用使用同一时窗，方案一致。 |
| CPU 历史图 | 当前 CPU 样本序列 | D | 1 分钟保留快速样本，24 小时使用分钟样本；不是系统重启前的历史。 |
| Top CPU 进程 | 进程累计 CPU 时间差 / 采样间隔 | B/D | 允许单进程超过单核 100%；UI 当前按采样值排序。 |

官方依据：[host_processor_info](https://developer.apple.com/documentation/kernel/1502854-host_processor_info)。

## 3. 内存

| 数据 | 当前来源 | 评级 | 核对结论 |
| --- | --- | --- | --- |
| Total | `ProcessInfo.physicalMemory` | A | 官方公开接口。 |
| Free | `HOST_VM_INFO64.free_count × pageSize` | A/D | 定义正确。 |
| Cached | `(inactive_count + speculative_count) × pageSize` | A/D | 是 Moni 的“可回收缓存”口径，不等同于 Activity Monitor 的 Cached Files 精确实现。 |
| Used | `Total - Free - Cached` | D | 是应用定义的实际占用口径；不能称作 Memory Pressure。 |
| Used % | `Used / Total` | D | 计算正确。 |
| Wired | `wire_count × pageSize` | A/D | 计算正确。 |
| Compressed | `compressor_page_count × pageSize` | A/D | 计算正确。 |
| Swap used | `sysctl vm.swapusage` | B | 系统接口，继续使用。 |
| Page ins | `vm_statistics64.pageins` | A | 累计计数。 |
| Page outs | `vm_statistics64.pageouts` | A | 累计计数。 |
| Faults | `vm_statistics64.faults` | A | 累计计数。 |
| 内存历史图 | `Used %` 样本序列 | D | 语义为占用率历史。 |
| Usage status | Used % 的 80%/90% 阈值 | D | 已将小组件中的错误名称 `Pressure` 改为 `Usage/Status`；真正的 macOS Memory Pressure 不是单纯使用率。 |
| Top memory 进程 | `proc_taskinfo.pti_resident_size` | B | 是 resident size，不是完整 footprint；界面应保持“Memory”而非“App Memory”措辞。 |

官方依据：[host_statistics64](https://developer.apple.com/documentation/kernel/1502863-host_statistics64)。

## 4. 网络

| 数据 | 当前来源 | 评级 | 核对结论 |
| --- | --- | --- | --- |
| 下载/上传速率 | 所有非 loopback 接口 `if_data` 字节计数差 / 时间 | B/D | 表示本机接口合计流量；VPN/bridge 可能重复计入，不能解读为运营商 WAN 速率。 |
| Received/Sent total | 所有非 loopback 接口累计字节 | B/D | 与速率口径一致，是本次开机以来的接口计数。 |
| 接口名、IPv4/IPv6、活跃状态 | `getifaddrs` | B | 标准本地接口枚举。 |
| 接口类型 | `SCNetworkInterfaceCopyAll` | A | 公共 SystemConfiguration 接口。 |
| 主接口、网关 | `SCDynamicStore` 的当前网络状态 | A/B | 系统动态状态查询，继续使用。 |
| Wi‑Fi SSID | `CoreWLAN.CWInterface.ssid` | A | 公开接口；受系统隐私权限影响时允许为空。 |
| Wi‑Fi RSSI | `CWInterface.rssiValue` | A | 公开接口，单位 dBm。 |
| Wi‑Fi PHY/频道/频段 | `CWInterface.activePHYMode/wlanChannel` | A | 公开接口；枚举到文字的映射需要随新 macOS 检查。 |
| Wi‑Fi 传输速率 | `CWInterface.transmitRate` | A | 是当前链路速率，不是互联网吞吐。 |
| 非 Wi‑Fi 链路速率 | `if_data.ifi_baudrate` | B | 继续使用。 |
| 活跃连接进程/端点/协议/流量 | `/usr/bin/nettop -L 1` | B | Apple 系统工具，但 CSV 输出没有稳定 SDK 契约；只在网络页打开时每 5 秒运行。 |
| 公网 IP | `https://api.ipify.org` | 外部服务 | 返回调用时出口 IP；不是 Apple 数据。失败时为空。 |
| IP lookup 时间 | 对 ipify HTTPS 请求的总耗时 | D | 包含 DNS、TLS、服务端与网络时间；不是 ICMP ping，界面应继续叫 IP lookup。 |
| 网络历史图 | 下载/上传样本序列 | D | 跟随当前接口合计口径。 |

官方依据：[CoreWLAN](https://developer.apple.com/documentation/corewlan)、[System Configuration](https://developer.apple.com/documentation/systemconfiguration)。

## 5. 存储与磁盘

| 数据 | 当前来源 | 评级 | 核对结论 |
| --- | --- | --- | --- |
| 卷名、格式、挂载点 | `mountedVolumeURLs` + `URLResourceValues` | A | 官方公开接口。 |
| 总容量、可用容量 | `volumeTotalCapacity/volumeAvailableCapacity` | A | 当前显示“Free/Available”，语义正确；如未来表示“可安全写入量”应改用 `volumeAvailableCapacityForImportantUsage`。 |
| 已用容量与百分比 | 总容量 - 可用容量 | D | 计算正确。 |
| 读写字节/秒 | `IOBlockStorageDriver/Statistics` 累计值差 | C/D | I/O Registry 键未公开文档化；没有同等低成本公开实时 API。 |
| 读写 IOPS | 同一 Statistics 的操作次数差 | C/D | 同上。 |
| 最大目录 | 低优先级执行 `du -sk -x` | B | 只统计同一文件系统，避免跨挂载点；结果缓存 6 小时。权限不可读内容不会被统计。 |
| `/System` 占用 | `diskutil info -plist /` 的 `CapacityInUse` | B | 系统工具结构化输出；避免递归扫描只读系统卷。 |
| 盘型号、S.M.A.R.T.、TRIM、温度、总写入量 | NVMe/IOKit bridge | C | Apple 没有提供等价公共 SDK；必须允许不同硬盘或 macOS 版本返回空值。 |

官方依据：[URL resource keys](https://developer.apple.com/documentation/foundation/urlresourcekey)、[volumeAvailableCapacityForImportantUsage](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeavailablecapacityforimportantusagekey)。

## 6. 进程

| 数据 | 当前来源 | 评级 | 核对结论 |
| --- | --- | --- | --- |
| PID | `proc_listallpids` | B | Darwin/libproc 接口。 |
| 名称、可执行路径 | `proc_name/proc_pidpath` | B | 无权限时使用保守回退值。 |
| CPU % | `pti_total_user + pti_total_system` 的差值 | B/D | 2 秒采样；隐藏时 30 秒。 |
| Resident memory | `pti_resident_size` | B | 是驻留内存。 |
| Threads | `pti_threadnum` | B | 当前线程数。 |
| 排序和 Relative CPU 条 | 上述 CPU % 相对当前最高项 | D | 视觉比较，不是另一套采样。 |

结论：当前一次枚举复用所有进程字段，并缓存名称/路径，已经避免每个页面重复调用；没有发现额外高频进程扫描。

## 7. 电池、温度、风扇与功耗

| 数据 | 当前来源 | 评级 | 核对结论 |
| --- | --- | --- | --- |
| 电量、充电状态、剩余/充满时间 | IOKit Power Sources (`IOPS*`) | A | Apple 公开接口，继续使用。 |
| 外接电源 | `AppleSmartBattery.ExternalConnected` | C | 未公开 registry 键；公开 IOPS 没有完全等价字段。 |
| 电池温度、循环次数、电压、电流 | `AppleSmartBattery` registry 属性 | C | 未公开键，允许为空。 |
| 电池健康文字 | `PermanentFailureStatus` 推导 | C/D | 只能给出粗粒度 Normal/Service recommended，不等同系统设置的完整健康诊断。 |
| 电池健康百分比 | `AppleRawMaxCapacity / DesignCapacity` | C/D | 是容量保持率估算，不是 Apple 对外承诺的“效率”。 |
| System input 功率 | `PowerTelemetryData.SystemPowerIn` | C | 未公开键，允许为空。 |
| CPU/GPU/ANE/RAM 功率 | Apple Silicon IOReport 能量计数差 / 时间 | C/D | 私有采样；没有等价公开 API。 |
| CPU/GPU 温度及全部传感器 | IOHIDEventSystemClient，M3 回退到 SMC 键 | C | 私有传感器名称可能变化；已有 0–110°C 合理值过滤。 |
| 风扇转速 | SMC `FNum/FxAc` | C | 私有 SMC 键；无风扇设备返回空值。 |
| 温度/电池历史图 | 上述当前值样本序列 | D | 只包含 Moni 运行期间的数据。 |

官方依据：[IOKit Power Sources](https://developer.apple.com/documentation/iokit/kiopscurrentcapacitykey)、[time to empty](https://developer.apple.com/documentation/iokit/kiopstimetoemptykey)。

## 8. GPU 与显示器

| 数据 | 当前来源 | 评级 | 核对结论 |
| --- | --- | --- | --- |
| GPU 名称、registry ID | `MTLCopyAllDevices` / `MTLDevice` | A | 官方 Metal 接口。 |
| 统一内存能力 | `MTLDevice.hasUnifiedMemory` | A | 官方接口。 |
| 统一内存总量 | 统一内存设备复用物理内存容量 | A/D | Apple Silicon 口径正确。 |
| GPU 核心数、Metal family、vendor | 一次性 `system_profiler SPDisplaysDataType -json` | B/C | 没有等价公共字段；只在首次加载运行，不进入快速采样。 |
| 显示器像素分辨率、刷新率、物理尺寸 | Core Graphics | A | 本次已替换未公开 JSON 解析。 |
| GPU/Renderer/Tiler % | `IOAccelerator/PerformanceStatistics` | C | 未公开 registry 键；无公共实时全系统利用率 API。 |
| GPU allocated memory | `IOAccelerator` 的全系统分配字段 | C | 保留现有方案；`MTLDevice.currentAllocatedSize` 只适合当前进程创建的 Metal 资源，语义不同，不能替换。 |
| GPU 客户端名称、内存、利用率 | IOAccelerator 客户端累计时间 + libproc | C/D | 私有结构；以 PID 做差并允许进程退出。 |

官方依据：[MTLDevice](https://developer.apple.com/documentation/metal/mtldevice)、[currentAllocatedSize](https://developer.apple.com/documentation/metal/mtldevice/currentallocatedsize)、[CGDisplayMode](https://developer.apple.com/documentation/coregraphics/cgdisplaymode)。

## 9. Docker

| 数据 | 当前来源 | 评级 | 核对结论 |
| --- | --- | --- | --- |
| 是否安装、提供者 | Docker Desktop、OrbStack、CLI 的已知安装路径 | B | 能覆盖当前支持的本地提供者，但不是 Docker context 的完整实现。 |
| 是否运行、socket 路径 | 对已知 Unix socket 做只读连接测试 | B | 不启动 daemon，不修改 Docker 状态。 |
| 容器名、state、status、运行数/总数 | Engine API `GET /v1.40/containers/json?all=1` | 官方产品 API | 已补上官方要求的 API 版本；1.40 是当前 Docker Engine 文档列出的最低支持版本。 |

限制：`DOCKER_HOST`、`DOCKER_CONTEXT` 和任意自定义 context 还不能被当前路径扫描识别。官方最完整方案是 context/SDK API negotiation，但每 15 秒启动 Docker CLI 会增加明显开销；在没有常驻轻量 SDK 的现状下，保留已知本地 socket 是性能更稳妥的取舍。

官方依据：[Docker contexts](https://docs.docker.com/engine/manage-resources/contexts/)、[Engine API](https://docs.docker.com/reference/api/engine/)、[Engine API v1.40](https://docs.docker.com/reference/api/engine/version/v1.40/)。

## 10. 模型用量、费用与额度

| 数据 | 当前来源 | 评级 | 核对结论 |
| --- | --- | --- | --- |
| Codex tokens/input/output/cache/reasoning/requests/sessions/model | `~/.codex/sessions` 与 archived JSONL 增量解析 | E | 本地产品日志，不是公开 API；已有文件签名缓存、增量读取、分支前缀去重。 |
| Claude Code 同类字段 | `~/.claude` JSONL 增量解析 | E | 本地产品日志；已有事件 reconciliation 与持久缓存。 |
| Qwen Code 同类字段 | `~/.qwen/usage` 与 `usage_record.jsonl` | E | 以 request ID/session ID 去重；日志格式可能变化。 |
| Gemini CLI 同类字段 | Gemini/Antigravity 本地 session 文件 | E | 本地格式，允许无法解析的记录成为 unpriced。 |
| DeepSeek Harness 同类字段 | 本地 usage 日志 | E | 本地格式，按稳定 ID 去重。 |
| OpenCode/Kimi 同类字段 | 本地数据库、消息或 wire 日志 | E | 本地格式，不假定每条记录都包含完整 token。 |
| 今日/30 天/90 天/全部总 token | 对选定本地日期区间汇总 | D | 30 天含今天共 30 个自然日；柱状图会补齐没有记录的日期为 0。 |
| 每日 provider breakdown | 同一天按 provider 聚合 | D | tooltip 使用真实来源集合，不写死 Claude/Codex。 |
| Cache hit % | cache-read / (input + cache-read + cache-write) | D | 是 Moni 统一口径，不等同各厂商账单页面可能采用的口径。 |
| Priced entries | 有价格映射的请求数 / 总请求数 | D | 未知模型不会用相近模型价格猜测。 |
| 费用估算 | 本地 token × 官方 API list price | D | 不是订阅发票；长上下文、缓存读写按公开规则计算。 |
| OpenAI 模型价格 | OpenAI 官方 model/pricing 文档 | 提供商官方 | GPT-5.6 Sol/Terra/Luna 与公开长上下文倍率已核对。 |
| Claude 模型价格 | Anthropic 官方 pricing 文档 | 提供商官方 | 输入、输出及 5m/1h cache 写入倍率已核对。 |
| Gemini 模型价格 | Google Gemini API 官方 pricing | 提供商官方 | standard 非 batch 价格已核对。 |
| DeepSeek 模型价格 | DeepSeek 官方 pricing | 提供商官方 | 当前正式价格仍是现有基础价；官方只预告未来 peak/off-peak，因此没有提前套用尚未生效的价格。 |
| Qwen 模型价格 | Alibaba Cloud Singapore / International list price | 提供商官方 | 本次改为按单次输入规模分档；缓存命中按官方 implicit cache 的 20% 输入价。没有套用临时折扣。 |
| Codex plan、5-hour/weekly 使用率和重置时间 | `chatgpt.com/backend-api/wham/usage` | F | ChatGPT/Codex 订阅没有公开等价开发者 API；失败时保留近期缓存，不显示虚构 100%。 |
| Claude plan、5-hour/weekly/scoped 使用率和重置时间 | `api.anthropic.com/api/oauth/usage` | F | Claude Code OAuth 内部接口，不属于公开 API；允许字段缺失。 |
| 预估 weekly 美元额度 | 当前 quota window 内本地 API 等价成本 / 已用比例 | D | 是“按本地日志与 list price 推导的等价额度”，不是厂商公布的美元上限。 |

官方依据：[OpenAI models](https://developers.openai.com/api/docs/models)、[GPT-5.6 Sol](https://developers.openai.com/api/docs/models/gpt-5.6-sol)、[Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing)、[Gemini pricing](https://ai.google.dev/gemini-api/docs/pricing)、[Alibaba Cloud model pricing](https://www.alibabacloud.com/help/en/model-studio/model-pricing)、[Alibaba Cloud context cache](https://www.alibabacloud.com/help/en/model-studio/context-cache)、[DeepSeek pricing](https://api-docs.deepseek.com/quick_start/pricing/)。

## 11. 菜单栏、小组件、告警与图表

| 数据 | 当前来源 | 评级 | 核对结论 |
| --- | --- | --- | --- |
| 菜单栏 CPU/Memory/Network/Disk/Battery/Temp | 当前 `SystemSnapshot` 与对应历史 | D | 不另起采样器；多选只改变渲染。 |
| 菜单栏模型用量 | 30 天 dashboard cache | D/E | 不在每个系统 tick 扫描日志。 |
| 首页及详情图表 | recent/minute history | D | 1m 使用快速历史，1h/24h 使用分钟历史；tooltip 是同一个样本值。 |
| 小组件全部系统数值 | 每 15 秒落盘一次的 snapshot | D | 避免每 0.3–0.7 秒写共享容器。 |
| 小组件 timeline | 最快 5 分钟请求一次 reload | WidgetKit 策略 | 避免耗尽 WidgetKit 刷新预算。 |
| CPU/Memory/Disk/Temperature 告警 | snapshot 与用户阈值比较 | D | 小组件和通知复用相同阈值。 |

## 12. 采样与性能核对

| 工作 | 面板打开 | 面板隐藏 | 结论 |
| --- | --- | --- | --- |
| CPU、内存、接口字节、磁盘计数、GPU 快照 | 用户设置的 0.3–5 秒 | 至少 2 秒 | 打开时保证曲线，隐藏时降低常驻开销。 |
| 进程列表 | 2 秒 | 30 秒 | 名称/路径按 PID 缓存；合理。 |
| 电池、温度、卷、网络元数据 | 5 秒 | 60 秒 | 私有传感器不跟随 0.3 秒主循环；合理。 |
| 网络连接 `nettop` | 5 秒且仅网络页可见时 | 暂停 | 正确避免后台子进程。 |
| Docker | 15 秒 | 60 秒 | curl 超时 1 秒；请求只读。 |
| 最大目录 | 首次需要时，缓存 6 小时 | 同左 | `taskpolicy -b` + `nice 20`，避免抢占前台。 |
| 公网 IP/IP lookup | 按需，成功后缓存 10 分钟 | 同左 | 超时 5 秒，不进入主采样循环。 |
| 模型 quota | 需要时，缓存 5 分钟 | 同左 | 无重置时间的有效旧额度最多保留 30 分钟。 |
| 小组件快照 | 15 秒落盘 | 15 秒落盘 | timeline reload 最快 5 分钟。 |

没有发现主采样重入：`SystemMonitor.refreshTask` 在上一轮完成前会拒绝新一轮，因此慢采样不会并发堆积。

## 13. 本次已处理与仍需明确授权的项目

已处理：

1. 屏幕像素分辨率与刷新率改用 Core Graphics 公开 API。
2. Docker 容器列表改用带版本的 `/v1.40/containers/json`。
3. 小组件内存阈值由错误的 `Pressure` 改为 `Usage/Status`。
4. Qwen International 价格改为官方分档价格，并依据每次请求输入规模选档。

保留但明确标注限制：

1. GPU 全系统利用率/分配内存、温度、风扇、功耗和 NVMe 健康数据没有语义相同的公开 API，不能为了“公开”而换成错误含义的数据。
2. Codex 与 Claude 订阅额度没有公开开发者 API；现有内部接口只能作为可失败的增强数据源。
3. 网络总流量是所有非 loopback 接口合计。若要改成“主接口/WAN 口径”，会改变现有数据定义，需要单独确定产品口径。
4. Docker 自定义 context 尚未覆盖。完整支持需要引入 context 解析或 Docker SDK，属于新增能力，不在本次最小准确性修复中。
