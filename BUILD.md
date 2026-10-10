# 构建管线文档（BUILD.md）

FlClash iOS MG —— 唯一仓库文档。内核构成、版本与完整构建管线都在本文。

## 0. 项目构成

- Flutter 多平台工程（iOS Network Extension / Android / 桌面），上游基线 v0.9.4
- 内核 vendor 在 `core/mihomo/`：mihomo FlClash 基座（293cd231，随 v0.9.4）+ 私有协议套件
  - `x365`（365VPN/efan，VLESS 衍生，xhttp stream-one + REALITY）
  - `xhttp`（黑石，含 2026-09 key1 轮换修复）
  - `anytls`（`#SL` 后缀闪连，Chrome 指纹派生）
  - `oppa`（Trojan 风格裸 TLS 隧道）
  - `trojan`(mpw)（FastUP，自动 h2mux SingMux）
  - ViewTurbo SS（`core/sing-shadowsocks2-viewturbo`，`#viewTurbo` 密码后缀）
- 平台标识统一为 `cc.flclash.mg`（iOS bundle id / Android applicationId / 桌面 id）
- iOS 内存调度（`with_low_memory` 构建）：GOGC=30 + 20MB 堆软限；串行规则加载 +
  每 provider 即时 GC；单规则集 6000 条 clamp；footprint 分级归还（10s 常规 /
  2s 应急 ≥34MB）；x365 transport 懒初始化 + 3 分钟闲置淘汰

---

本文档描述 FlClash-iOS-MG 的完整构建管线：本地构建、CI 构建、签名安装与产物校验。

---

## 1. 环境要求

| 组件 | 版本 | 说明 |
|---|---|---|
| Flutter | 3.47.6（master channel） | 与 CI 对齐；其他版本未验证 |
| Go | 1.26.x | 内核构建；低版本未验证 |
| Xcode | 26.2 / 26.3 | 仅 macOS 构建需要 |
| CocoaPods | 最新稳定版 | `pod install` 由 flutter build 自动触发 |
| Rust + Cargo | 最新稳定版 | `plugins/rust_api` 需要 |

> 内存调度优化（`with_low_memory` 构建标签）对 Go 1.21+ 均可用；但生产构建请用 Go 1.26.x，与 CI 一致。

---

## 2. 源码获取

```bash
git clone --recursive <本仓库地址>
cd FlClash-iOS-MG
```

内核已 vendor 进仓库（`core/mihomo/`、`core/sing-shadowsocks2-viewturbo/`），无外部 submodule 依赖，clone 后即可构建。

### 2.1 内核完整性自检（可选但推荐）

```bash
# 协议注册标记（4 个私有协议必须在 parser.go 中注册）
grep -E 'case "(x365|xhttp|oppa|anytls)":' core/mihomo/adapter/parser.go
# 期望输出 4 行

# x365 协议关键代码
grep -n 'magic = \[4\]byte' core/mihomo/transport/x365/conn.go
grep -n 'invalid response magic' core/mihomo/transport/x365/conn.go

# 黑石 key1 轮换修复标记
grep -F 'do not hack this protocol please' core/mihomo/transport/blackstonexhttp/conn.go

# iOS 内存调度标记
grep -F 'SetGCPercent(30)' core/lowmem.go
grep -F 'fast-emergency' core/lib.go
grep -F 'EvictIdleLazyClients' core/mihomo/adapter/outbound/lazy_registry.go
```

全部命中即源码完整。

---

## 3. CI 构建（推荐）

### 3.1 ios-build 工作流

文件：`.github/workflows/ios.yaml`，手动触发（`workflow_dispatch`）。

```
Actions 页 → ios-build → Run workflow
  └─ build_env: stable / pre / dev（默认 stable）
```

bundle id 固定为 `cc.flclash.mg`（工作流内写死，无输入参数），每次构建的包标识恒定，**可直接覆盖安装升级**。

命令行触发：

```bash
gh workflow run ios.yaml --ref main -f build_env=stable
```

### 3.2 工作流执行步骤（约 15~25 分钟）

1. **Checkout**：完整历史 + 递归检出
2. **Verify vendored private kernel markers**：校验 4 个私有协议在 parser.go 的注册 + 关键传输层文件存在（缺一即 fail，防止空内核出包）
3. **Setup Flutter / Go**：3.47.6 + 1.26.8，带缓存
4. **Go protocol tests**：跑 `core/mihomo` 的协议单测（x365/xhttp/anytls/oppa/trojan/viewturbo 全链路回归）
5. **Install dependencies**：`flutter pub get`
6. **Build unsigned IPA**：`dart setup.dart ios --env stable --no-codesign -v`
   - setup.dart 完成 pbxproj 注入（bundle id）、xcconfig 生成、pod install
7. **IPA 内 x365 标记校验**：解包 IPA 后 grep 二进制中的 `invalid x365 response header`（确保编进去的是魔改内核而非上游原版）
8. **Upload artifact**：`FlClash-ios-arm64-unsigned`，保留 3 天

### 3.3 下载产物

```bash
RUN_ID=$(gh run list -w ios.yaml --limit 1 --json databaseId -q '.[0].databaseId')
gh run download $RUN_ID -n FlClash-ios-arm64-unsigned -D dist_download
ls dist_download/
# FlClash-<version>-ios-arm64-unsigned.ipa
```

### 3.4 build 工作流（.github/workflows/build.yaml）

通用多平台构建（Android/桌面），与 iOS 无关，按需触发。

---

## 4. 本地构建（macOS）

```bash
# 依赖就位后
dart setup.dart ios --env stable --no-codesign -v
# 产物: dist/FlClash-*-ios-arm64-unsigned.ipa
```

参数说明：
- `--env stable|pre|dev`：应用环境（影响应用名后缀与 flavors）
- `--no-codesign`：跳过签名（产出 unsigned 包，适合 TrollStore/自签）
- `--ios-bundle-id <id>`：覆盖 bundle id；默认 `cc.flclash.mg`。为保证覆盖安装升级，建议保持默认值不变

### 4.1 内核单独编译验证（Linux/任意平台，不出包）

```bash
cd core/mihomo
go build -tags "with_low_memory with_gvisor" -ldflags "-s -w" -o /tmp/mihomo-check .
go test ./adapter/outbound/ ./rules/provider/
go vet ./...
```

---

## 5. 签名与安装

unsigned IPA 的三种安装路径：

### 5.1 TrollStore（iOS 14.0~16.6.1 / 17.0 部分版本）

直接用 TrollStore 打开 IPA 安装，无需签名。NE 权限完整保留（entitlements 在包内）。

### 5.2 Apple ID 侧载

安装和信任主 App 不等于 Packet Tunnel 扩展获准运行。以**重签后的每个组件**的实际签名和 provisioning profile 为准：主 App、NECore、Widget 必须分别匹配自己的 App ID/Team，Network Extension 需要 profile 允许 `packet-tunnel-provider`。免费/个人团队未获准的 capability 不能通过 JIT、写 plist 或本项目源码补齐。

### 5.3 开发者证书签

使用具备所需 capabilities 的签名服务/开发者团队，逐个生成匹配的描述文件并正确重签。不要把模板里的 `$(APP_BUNDLE_ID)` 或分发包的 `UNKNOWN000` 当成已生效授权。

- 由内向外重签：嵌入框架/dylib → NECore/Widget → 主 App；最后验证完整签名。
- 主 App 与每个 `.appex` 分别嵌入自己的 `embedded.mobileprovision`，不能复用主 App 的 profile 给扩展。
- 保持 Team、主 App/扩展 Bundle ID、签名 entitlements 和 profile 中的允许值一致。若使用 App Groups，各组件必须有同一个**真实获准**的 group。
- 本项目支持 App Group 不可用时通过 `providerConfiguration` 传递启动载荷，但这不替代系统对 Network Extension entitlement 的检查。
- 覆盖安装还要求重签后的 App ID/Team 与已安装版本匹配，不只有构建模板 Bundle ID 相同。先备份配置，不把卸载作为首个排障步骤。

---

## 6. 产物校验

### 6.1 基础校验

```bash
md5sum FlClash-*-unsigned.ipa   # 与发布方提供的 MD5 对比
unzip -l FlClash-*-unsigned.ipa | head -20   # 结构: Payload/Runner.app + PlugIns/NECore.appex + PlugIns/Widget.appex
```

### 6.2 协议标记校验（确认魔改内核在包内）

```bash
unzip -q FlClash-*-unsigned.ipa -d verify
strings verify/Payload/Runner.app/PlugIns/NECore.appex/NECore | grep -c "x365"
# ≥1 即魔改内核已编入（上游原版内核此计数为 0）

strings verify/Payload/Runner.app/PlugIns/NECore.appex/NECore | grep -F "invalid x365 response header"
# 有输出 = x365 协议代码完整

strings verify/Payload/Runner.app/PlugIns/NECore.appex/NECore | grep -F "build	-tags"
# 期望: build -tags=with_gvisor,with_low_memory
```

### 6.3 内存调度标记校验

```bash
strings verify/Payload/Runner.app/PlugIns/NECore.appex/NECore | grep -F "fast-emergency"
strings verify/Payload/Runner.app/PlugIns/NECore.appex/NECore | grep -F "EvictIdleLazyClients"
strings verify/Payload/Runner.app/PlugIns/NECore.appex/NECore | grep -F "Go memory soft limit"
```

三者都有输出 = 内存调度代码完整编入。

---

## 7. 实机验收清单

安装后按顺序验证（对应本文 0. 节内存调度要点）：

| # | 场景 | 期望 |
|---|---|---|
| 1 | 启动 VPN 后 1 分钟（加载 121 节点 + 20 规则集） | 不闪退；日志 `[MEM] footprint=` 稳定在 15~22MB |
| 2 | 应用内全组测速 | 全部完成；测后 footprint ≤ 25MB；无 `memory_pressure_critical` 连环出现 |
| 3 | 挂机 10 分钟 | 不断流；每 10s 一条 `reclaim (routine)` |
| 4 | 触发 footprint≥34MB（大量并发下载） | 出现 `reclaim (fast-emergency)` 后回落；连接不中断 |
| 5 | 各协议节点逐一切换 | x365 / 黑石 xhttp / anytls(#SL) / oppa / FastUP / viewTurbo 全部可连通 |

日志获取：应用内 日志页 → 按等级过滤 info，搜 `[MEM]` 与 `[NE]`。

---

## 8. 常见问题

**Q: CI 在 Verify markers 步骤失败？**
A: 内核文件缺失或协议未注册。检查 `core/mihomo/adapter/parser.go` 的 4 个 case 是否在。

**Q: Build unsigned IPA 步骤报 Go 编译错误？**
A: 大概率是 lib.go 的 cgo 分支（`(android||ios)&&cgo`）问题——本地 Linux 构建不会编译这个分支，只有 CI/macOS 会走到。修复后需在 CI 验证。

**Q: 本地构建 Rust 报错？**
A: `plugins/rust_api` 需要 Rust 工具链：`rustup update stable`。

**Q: 实机 NE 启动后立刻断开？**
A: 先看 `[VPN-DIAG] launch` 和 `lastDisconnectError` 的 domain/code。系统可能在扩展入口前拒绝启动；VPN 列表有条目不能排除签名问题。若有 NE 的 footprint 记录，再结合 JetsamEvent/崩溃日志判断内存，不以 Linux RSS/Private_Dirty 代替 iOS phys_footprint。

**Q: 重签后共享容器/组名变化怎么处理？**
A: `ios/Shared/SharedLocation.swift` 统一解析：优先逻辑组 `group.<bundle id>`；不可用时在授权组（SecTask 读取）中找唯一可打开容器的组并映射过去；多于一个可用组时拒绝猜测，回落到启动载荷/沙盒链路。主 App（`SharedStateStore`）、NE（`PacketTunnelSharedStateStore`）、Widget、Dart 数据目录（`path.dart` 经 `getAppGroupPath` 通道）四处共用同一决策，不允许出现 App 与扩展各用各的根目录。Dart 侧通道未就绪时回退到 path_provider 的逻辑组查询。

**Q: 带 rule-providers 的配置（x365/黑石/fastup 等）启动要 10+ 秒？**
A: 内核 `loadProvider` 的低内存构建（iOS NE 是 `with_low_memory`）里 `concurrentCount = 1`，而信号量获取写在了主循环里：上一个 provider 加载不完（含网络超时）就轮不到下一个，整个 applyConfig 被 rule-providers 串行阻塞——`raw.githubusercontent.com` 类规则源在国内直连必超时（20s 上限）且永远无缓存，每次启动都重新等。修复：信号量获取移入 goroutine，spawn 循环瞬间返回，隧道立即启动；provider 仍按 lowmem 限速在后台逐个加载，规则异步热身。参考包内核是同一段代码，但其 App Group 让 provider 缓存从不缺失，所以从未触发。

**Q: 自签（无 App Group）下网速卡片/日志/连接面板没数据？**
A: NE 的核心事件原本只能写 App Group 目录（`core-events`），无组时全部丢失。现在 NE 维护 300 条内存环，App 在隧道运行期每秒（及收到 Darwin 通知时）通过 provider 消息 `neDrainEvents` 抽取并转发给 Flutter；巨魔等有组环境仍走原文件队列，两条通道互不干扰。

**Q: VPN 卡在 connecting 怎么定位？**
A: 启动等待 8 秒仍未完成时，协调器自动通过 provider 消息拉取 NE 飞行日志（`neDiagnosticLog`，含 payload/geo/quickSetup/startTun 每阶段毫秒时间戳）并注入 `[VPN-DIAG]`/`[NE]` 日志行；45 秒仍无果则主动停止半启动隧道。卡在哪一阶段，导出日志直接可见。

**Q: 重启期间 DNS 报 "listen udp 0.0.0.0:1053: bind: address already in use"？**
A: 重签环境的 NE 重启有进程重叠窗口，旧进程还占着 DNS/inbound 端口时新核心会 bind 失败（对整个会话致命）。修复在内核侧（对齐参考包能力）：`core/mihomo/adapter/inbound/listen.go` 的 Control 在 bind 前统一设置 SO_REUSEADDR+SO_REUSEPORT，新旧进程可同时持有端口，冲突消失。

**Q: 切换配置后连的还是上一个配置的节点？**
A: NE 核心的 config.yaml 只在隧道启动时由载荷写入，切换配置若只推送 setupConfig 会把旧配置重新 apply 一遍。现在三层防护：Dart 检测到配置变更且隧道在运行时直接重启隧道；Swift 协调器比对配置指纹（FNV-1a），会话期间配置变了强制 stop→save→start；路由器在指纹失配时拒绝对过期核心推送 setupConfig/updateConfig。另有 45 秒启动等待超时，避免 UI 永远停在加载。

**Q: 魔改配置提示 configuration is too large / empty network extension response？**
A: iOS 硬性限制 VPN 配置的 providerConfiguration 最大 524,288 字节，魔改订阅生成的 YAML（1MB+）直接塞载荷会被系统拒绝保存，隧道起不来，仪表盘方法调用全部报 empty response。处理：小配置（≤200KB）仍内联；更大时 App 端用 raw DEFLATE 压缩后放 `configYamlDeflate`（附 `configYamlSize` 原始长度），扩展端解码；压缩后仍超 430KB 预算则标记 `configOmitted` 并让启动报明确错误。另外 `handleAppMessage` 增加 15 秒看门狗：Go 核心不回话时返回 `core_timeout` 错误而不是静默无响应。门禁测试含压缩往返与扩展端解码用例。

**Q: 本轮载荷修复覆盖什么？**
A: 平铺启动字典、旧版嵌套 `launchPayload`、无 options 的系统/On Demand 启动、非法载荷回退，以及主 App 私有状态副本。`sh tool/ios/test_launch_payload.sh` 在 macOS 编译真实源码，先证明旧版失败，再验证新版。系统签名放行、首次 Geo 资源下载、无 App Group 的长期日志/运行状态同步仍需真机验证；不能把 CI 构建成功说成 iOS 自签实测通过。

**Q: 测速后 memory pressure 连环出现？**
A: 属正常防御路径：`memory_pressure_critical` → `memory_pressure_reclaimed` 成对出现且 footprint 回落即可；若只 critical 不 reclaimed 才是问题。


---

## 9. 发布

当前发布版本：**flclash-iOSMG 0.01**（tag `v0.01`）

- 产物：`FlClash-0.9.4-ios-arm64-unsigned.ipa`（bundle id `cc.flclash.mg`）
- 下载：仓库 Releases 页 `v0.01` 资产（免登录直链）
- 覆盖安装：bundle id 与工作流已固定，此后每次 iOS 构建出的 IPA 均可直接覆盖安装升级（TrollStore 直接打开 IPA 安装即可），无需卸载
- 发布流程：
  ```bash
  # 1. 触发构建并等待完成
  gh workflow run ios.yaml --ref main -f build_env=stable
  # 2. 从 run 下载产物 IPA
  gh run download <run-id> -n FlClash-ios-arm64-unsigned -D dist
  # 3. 创建 GitHub Release 并上传 IPA
  gh release create v0.0X dist/*.ipa --title "flclash-iOSMG 0.0X" --notes "版本说明"
  ```
