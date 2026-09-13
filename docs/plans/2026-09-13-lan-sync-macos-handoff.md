# 多设备词库同步：Mac 接手续作与验收计划

**目标：** 在现有功能分支上完成 Mac 原生适配、安装授权和真实输入验收，验证至少六成员的同步组，再补齐正式交付所需的可靠性工作。

**架构：** Rust 辅助进程负责发现、配对、签名增量和持久状态；Swift/AppKit 客户端在空闲时通过官方 librime 维护接口导出、备份、应用与回读。Mac 与 Windows 使用同一协议，每台设备加入一次，数据传播不依赖创建者常开。

**技术栈：** Swift/AppKit/InputMethodKit、librime 桥接、Rust 1.92.0、SQLite、TLS 1.3、mDNS、macOS Keychain；Windows 对端为 C#/WPF 与 TSF/Broker。

本文件是下一阶段的执行入口。用户已要求在 Mac 继续开发、修复及真机实测，必要的构建和验证继续执行，不重复询问相同开发许可。系统原生认证由用户本人完成。先读仓库 [AGENTS.md](../../AGENTS.md)，每项取得实际证据后再勾选；本文件的未勾选项都不是通过结论。

## 1. 分支与已验证基线

| 项目 | 接手信息 |
| --- | --- |
| 仓库 | `asmoyou/rime-Q` |
| 继续使用的分支 | `codex/lan-dictionary-sync` |
| 初始 main 基线 | `d7080df49596311fbd7ce0a5d997935b3466f279`，交接前再次 fetch 后一致 |
| 最后一次已验证的功能代码 | `0497a254c77c1d846b18fee4645ba94e9f5f6df0`；本交接文档在其后的文档提交中 |
| 草稿 PR | [PR #3](https://github.com/asmoyou/rime-Q/pull/3)，base 为 `main`，尚未合并或发布 |
| 完整 CI | [push 检查](https://github.com/asmoyou/rime-Q/actions/runs/34758133390)、[PR 检查](https://github.com/asmoyou/rime-Q/actions/runs/34758135604)，上述功能提交的两套 12 项检查均成功 |
| Windows 开发工作区 | `C:/Users/36527/Downloads/rime-Q-lan-sync`，功能与交接文档均推送到同一分支 |

Mac 先在已有仓库运行：

```sh
git fetch --prune origin
git status --short --branch
git worktree list
```

若已有此分支工作区，进入它并在工作区干净时 `git pull --ff-only`。若本地尚无同名分支，可在现有仓库创建独立工作区：

```sh
git worktree add -b codex/lan-dictionary-sync ../rime-Q-lan-sync origin/codex/lan-dictionary-sync
cd ../rime-Q-lan-sync
git merge-base --is-ancestor 0497a254c77c1d846b18fee4645ba94e9f5f6df0 HEAD
```

最后一条应返回 0。若已有同名本地分支，使用已有分支或工作区，不重复执行创建命令，不用 reset/强推覆盖本地工作。若接手时 main 有新提交，先审查差异，再按正常 Git 流程整合并验证。Windows 原工作区 `rime-Q` 中另有未跟踪的最初提案，已保留；继续开发以功能分支的文档为准。

## 2. 已完成及证据边界

| 范围 | 实际结果 | 不能由此推断 |
| --- | --- | --- |
| Rust 核心 | 10 项集成测试、1 项快照保留测试及 Clippy 通过 | 原生安装和输入可用 |
| 六个隔离服务进程 | 11 项真实 TLS 场景通过，39.71 秒 | 六台独立机器通过 |
| 六个 Docker 节点 | 真实 mDNS、3+3 分区、恢复、创建者关机、删除/重启等通过 | 六台独立内核 VM 通过 |
| 最新二十节点重跑 | 10 项通过，148.07 秒，含发现线程上限及 10+10 分区；镜像 `sha256:7e1ed992c186dbd9de85d18fdfa02f0e1f3736ec385c28fd2e60b1a5032e4e16` | 五十节点或长期运行通过 |
| Windows Sandbox | 单台 Windows 10.0.19041 VM 内六个真实 librime 数据库、x64/x86 TSF、六引擎/TLS 完整链路通过；完整链路 5 项/24.96 秒 | Mac 适配器或跨平台真机通过 |
| Windows 原生 UI | 六设备列表、暂停/恢复及 WPF 渲染已操作和目视检查 | Mac 同步窗口已经验收 |
| Mac CI | 编译、通用包、现有引擎/UI/安装相关检查通过 | 安装应用的本地网络/Keychain 权限及真实宿主同步已经通过 |

已提交的跨机器证据摘要：[lan-sync-2026-09-13.json](../validation/lan-sync-2026-09-13.json)。详细解释见 [VALIDATION.md](../VALIDATION.md)；最终行为见 [LAN_SYNC.md](../LAN_SYNC.md)。摘要保留合成测试报告及来源报告摘要，不含配对码、控制令牌、私钥或真实个人词条。

`artifacts/`、`build-windows/`、`dist/` 是忽略目录，Mac 拉取分支不会得到 Windows 本机截图、完整日志、沙盒输入和安装包。需要 CI 产物时从上面指定运行取得 `RimeQ-macOS`、`RimeQ-Windows-x64`、`RimeQ-Windows-validation` 或 `RimeQ-sync-*`，先核对提交及可用性；若过期则在当前分支重建。原公开版本 `v0.4.0` 不含本功能，不能拿它代替这个分支的包。本轮没有替换 Windows 宿主现用输入法，已结束对应 Sandbox 并清理压力测试的任务资源。

## 3. 代码与测试入口

| 路径 | 用途与接手重点 |
| --- | --- |
| `macos/Sources/DeviceSync.swift` | 辅助进程、轮询、快照、应用、回执及恢复；`@MainActor`，跨 await 后重新核对组合输入；目前依赖共享实例与正式目录 |
| `macos/Sources/DeviceSyncWindow.swift` | 创建/加入、发现、邀请/确认、成员状态、暂停、移除、退出、恢复；需实际操作与视觉验收 |
| `macos/Sources/Engine.swift` | `Product.userRoot`、引擎启动与 `Engine.maintain`；维护调用在主线程，需测量对真实输入的影响 |
| `macos/Sources/PersonalDictionary.swift` | 官方导出、解析、手动词库操作和撤销；后台同步不能覆盖手动撤销备份 |
| `macos/Bridge/QRimeBridge.cpp`、`macos/Bridge/include/QRimeBridge.h` | 官方 librime 接口和 `QRimeLearningRevision`；不得复制运行中的 LevelDB |
| `macos/Sources/InputController.swift`、`macos/Sources/main.swift` | 组合状态、IMK/真实输入；启动/退出已接入同步服务；现有 smoke 分发 |
| `macos/Sources/DictionarySmoke.swift`、`ControllerSmoke.swift` | 现有隔离引擎/模拟客户端测试写法，供新增同步测试复用 |
| `scripts/build_macos.py`、`scripts/build_sync.py` | 生成 Info.plist、本地化权限用途、辅助程序通用构建及签名、依赖许可打包；Info.plist 由脚本生成 |
| `sync/src/service.rs` | 发现/邀请、TLS 会话、本机控制、调度及回执；发现代码在本文件，没有独立 `discovery.rs` |
| `sync/src/store.rs`、`model.rs`、`identity.rs`、`network.rs`、`backups.rs` | 因果合并、删除屏障、成员权限、Keychain/DPAPI、地址过滤及快照保留 |
| `scripts/test_lan_sync.py`、`test_lan_sync_sandboxes.py` | 可在 Mac 重跑的共用服务/容器测试；不测试 Swift 原生适配层 |
| `scripts/test_lan_sync_native.py`、`windows/tests/sync_engine_node.cpp` | 现有 Windows 六引擎链路；Python 使用 Windows 专用进程选项，不能直接当成 Mac 测试 |
| `.github/workflows/ci.yml` | 三平台核心与同步、六容器、Mac 包、Windows 包/安装；新增 Mac 同步测试需接入这里或 Mac 构建 smoke |

现有可执行基线命令（需要 Xcode/命令行工具、Python 3.11+、rustup；Rust 版本由 `sync/rust-toolchain.toml` 锁定）：

```sh
cd sync
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
cargo build --locked
cd ..
python3 scripts/test_lan_sync.py --binary sync/target/debug/rimeq-sync
python3 scripts/test_client_parity.py
python3 scripts/build_macos.py --universal --smoke
```

已有合格资源缓存时，最后一条可加 `--reuse-resources`。默认只交付 PKG、删除临时 `.app`。仅开发安装流程才使用 `--keep-app` 配合 `scripts/install_macos.py`；保持相同 Bundle ID 只有一个实际安装，避免预览污染现用输入源。

Docker 可用时的现有组网命令：

```sh
docker build -f sync/Dockerfile.test -t rimeq-lan-sync:test .
python3 scripts/test_lan_sync_sandboxes.py --nodes 6 --output artifacts/lan-sync-mac-containers-6.json
python3 scripts/test_lan_sync_sandboxes.py --nodes 20 --output artifacts/lan-sync-mac-containers-20.json
```

这些命令使用隔离测试身份和专用目录。正式客户端拒绝复用测试身份，不能将这些目录当作真实用户同步数据迁移进去。

## 4. Mac 优先任务

### M1：补原生同步适配层测试

- [ ] 先让 `DeviceSync` 可以注入测试根目录、偏好设置、词库实例和辅助程序路径；正式入口保持现有默认值。参考 `DictionarySmoke.personal()` 的临时目录及引擎初始化，不修改全局 HOME 或用户正式偏好。
- [ ] 新增 `macos/Sources/DeviceSyncSmoke.swift` 及必要的独立引擎测试入口，接入 `main.swift` 与 `build_macos.py`。这是待新增文件；当前没有 `--sync-smoke` 命令。
- [ ] 新增 `scripts/test_macos_sync_native.py` 或将现有原生测试适配为跨平台驱动，实际运行 Swift 同步代码和真实 librime。先固定可复现的失败/缺失覆盖，再修复，保持测试根目录和进程清理有边界。
- [ ] 覆盖导出 → 真实 TLS → 待应用 → 官方导入 → 回读 → 签名回执；每台引擎必须实际写回，不能用直接写辅助进程 SQLite 替代。
- [ ] 覆盖组合未结束时等待、await 期间开始新组合、await 期间新增学习、旧快照拒绝、中英文保持、降权/删除、重复操作、异常退出后的继续/恢复、重启保留及手动撤销备份保留。
- [ ] 专项复现关键时序：辅助进程收到远端删除，但引擎尚未应用；此时导出的旧学习不得被视为用户主动重新学入。只有引擎已应用删除后产生的新学习才能进入新代次。
- [ ] 将测试接入 Mac CI 并记录真实执行节点数。若先做单个 Mac 引擎加五个辅助进程，明确该覆盖范围，继续补齐原生落地验证。

验收：自动化测试确实执行 Mac 适配层；输入中不提前上屏、不吞键、不错误确认“已应用”；故障恢复后与预期词库一致，证据写入 `VALIDATION.md`。

### M2：真实安装、本地网络和 Keychain 授权

- [ ] 记录 Mac 型号/架构、系统版本、构建号、包摘要、已装位置和当前输入源。先用官方词库导出或引擎正常退出后的归档保留个人数据；不能在线复制 LevelDB 作为一致性备份。
- [ ] 使用此分支 PKG 的正常安装路径验证 `/Library/Input Methods/RimeQ.app`、Bundle ID、父输入法/子模式、辅助程序存在及实际签名。分开记录落盘、注册、启用和真实文本框输入，不把 API 返回 0 当成全部通过。
- [ ] 在已装应用中操作“个人词库 → 附近设备同步”，验证默认关闭时不进行 LAN 发现/监听；打开页面与启用/发现的权限触发时机按实际观察记录。
- [ ] 检查生成并安装后的 `NSLocalNetworkUsageDescription`、`NSBonjourServices`、中文/英文用途说明；实际核对系统将访问归属到 Rime Q 还是辅助进程，必要时修正打包/启动方式。独立 CLI 或开发预览的权限结果不替代已装应用。
- [ ] 覆盖首次允许、拒绝、之后在系统设置恢复；拒绝时保留本机输入/学习，界面能解释失败并恢复操作。不绕过 TCC/SIP，不使用全局权限重置。
- [ ] 使用正式模式验证 Keychain 服务 `com.asmoyou.inputmethod.RimeQ.sync` 的首次创建、应用重启后读取、拒绝/暂不可用时的错误处理及升级后身份保留。隔离测试不经过同一密钥存储，不能代替此项。
- [ ] 同步开启状态下验证升级/同版修复与登录重启：正常退出旧辅助进程、不重复启动、持续保持身份/组成员及词库。卸载保留数据、强制结束和故障注入放到专用测试账户/VM，不为回归卸载用户现用输入法。

验收：普通用户通过原生流程可完成安装和组网；权限拒绝不影响离线输入。真实签名、授权主体、首次启动/重启结果均有证据。当前构建采用 ad-hoc 签名，不能声称已具备 Developer ID 公证分发体验。

### M3：六设备真机同步与输入验收

- [ ] 列出 A–F 六成员的实际机器、系统、架构、客户端提交/构建号、连接方式与角色；至少包含 Mac 和 Windows。容器、同机进程或 VM 按其实际类型记录，设备不足时不得把二台真机加四个容器称为六台真机，但继续完成可执行的验证。
- [ ] 使用合成专用词和测试文档，通过原生页面完成五次加入；包含由非创建者邀请，验证一次加入后其余成员自动互认。成员列表能清楚显示六台设备及逐台应用状态。
- [ ] A–F 分别新增不同词条，在各自词库查看合并结果，并在真实文本框通过全拼候选和上屏确认。测试 Mac↔Mac、Mac↔Windows、Windows↔Windows 时记录实际可用组合。
- [ ] 验证同词不同读音、同代并发权重取最大值、明确降低权重、删除、离线旧学习回归、删除后真实重新学习。检查对端实际词库和签名应用状态，不只看发现列表或网络收包。
- [ ] 创建者关机后，其余设备继续学习/转发；创建者重开后补齐。创建者负责移除成员，但不是数据服务器。
- [ ] 在 Mac 持续组合输入时从其他设备更改词库：当前组合不被提前提交，结束后再应用；逐一验证首键、全拼、空格/数字/鼠标选词、取消、中英文切换、焦点变化和切换输入法后的首键。
- [ ] 真实宿主至少包含 TextEdit 和一个浏览器文本框；每次发送测试按键前确认前台应用及独立空白文档，避免向用户其他窗口发键。模拟 IMK 客户端结果单列。
- [ ] 逐项实际点击 Mac 同步 UI 的创建、加入、邀请、确认/拒绝、取消邀请、错误/过期码、暂停/恢复、立即同步、移除、退出、恢复快照及重新加入；检查短窗口、长设备名、六/二十设备列表、滚动和键盘焦点。截图不得保留配对码或真实词库内容。

验收：六成员规模与跨平台真机结果分别有明细。离线成员可能仍有未传播学习，UI 不应宣称所有设备始终实时一致。

### M4：网络变化、恢复与输入性能

- [ ] 覆盖睡眠/唤醒、锁屏恢复、Wi-Fi 切换、以太网/Wi-Fi 切换、地址变化、成员暂离和重连；正常可达网络恢复后无须重新配对或手填旧 IP。
- [ ] 覆盖实际 3+3、2+2+2 分区及接力路径；每个分区独立学习，恢复后逐节点检查收敛，重复路径不增加权重。现有容器脚本只覆盖两分区，三分区需要补测试入口。
- [ ] 在隔离测试身份/账户下按确切进程路径和 PID 注入辅助进程退出、引擎写入后未回执、过期快照与磁盘写入失败；确认自动写入暂停、错误可理解、双快照恢复可操作且无数据丢失。
- [ ] 记录同步关闭/开启、空闲/输入/批量同步时的输入延迟、主线程维护停顿、内存与空闲 CPU；注明机器、样本和缓存条件。尤其观察全量导出/比较发生在主线程时的真实停顿。
- [ ] 完成一次有记录的持续使用测试，建议至少 8 小时，包含睡眠/唤醒；报告实际时长、操作量和观察结果。发现等待或性能问题后定点修复，不以降低断言或延长所有超时掩盖失败。

## 5. 商用完善及共用协议剩余工作

这些不是单纯 Mac UI 工作。先完成 M1–M4 可取得的证据，再分独立提交处理；改动共用服务后同时验证 Windows。

| 优先级 | 待完成项 | 验收要求 |
| --- | --- | --- |
| P1 | 公共网络、VPN 与逐接口策略 | 现在仅按私有/链路本地 IPv4 过滤，没有平台级网络信任判断。明确 Mac/Windows 各自可用策略并实现发现和连接共用的接口选择；允许/拒绝、网络切换、多个接口有专项验证，不把私有 IP 等同于可信网络 |
| P1 | 管理权限迁移 | 当前只有创建者能移除成员。定义显式交接、签名授权、权限代次及失败恢复，测试旧管理者离线、旧授权重放、并发变更与重新加入；不能直接开放任意成员无序撤销而破坏收敛 |
| P1 | 历史检查点和压缩 | 操作历史尚不压缩。方案必须保留删除屏障、离线设备回归与成员撤销语义；明确过旧设备如何安全补齐/重建，不能按固定天数丢弃删除记录导致词条复活。自动快照保留已实现，不重复开发 |
| P1 | 大词库与协议上限 | 测试 32 MiB 原生快照、4 MiB 网络帧、20 万词条键及 128 个历史身份附近的边界、超限提示、分批、内存和异常恢复；限制不是实测性能承诺 |
| P1 | 五十节点压力与并发加入 | 在可用的独立环境取得完整通过证据；补多个已授权成员同时邀请新设备、并发成员变更的网络测试。不能因已有二十节点通过而关闭此项 |
| P2 | 设备管理与恢复体验 | 重命名、搜索/筛选、逐词恢复预览及更具体可处理的错误原因；既有恢复是先备份本机/目标，再明确采用本机，不是逐词冲突选择 |
| 后续平台 | Linux 正式客户端与密钥存储 | 当前 Linux 仅用于隔离服务测试，不宣称生产客户端已经支持 |

必须保留的协议约束：按原始来源的签名序号去重；序号缺口不推进确认；捕获使用引擎实际已应用的版本，不是辅助进程刚收到的版本；回执同时绑定数据版本和成员摘要；并发权重不求和。离线撤销不能远程收回已复制的词条，相关说明继续保留。

## 6. 五十节点失败交接

第一轮发现真实生命周期问题：反复邀请重建 mDNS 服务，旧浏览线程不退出，创建者达到 128 PID 限额；已经修正，最新二十节点含线程上限断言通过。第二轮发现通知 UDP 发送失败导致整个服务退出，已经改为保留服务并重试，部分初始化失败也做清理。

第三轮在 Windows Docker Desktop 29.6.2 / WSL2 5.15.153.1 下仍失败，262.27 秒，创建者仍运行且为 4 个线程，本机控制 TCP 超时。独立 Python 回环探针在原网络以及全新 `--network none` 容器中均复现 UDP `EINVAL`、TCP 超时；后者没有运行 Rime Q。停止五十节点负载后，独立探针恢复通过。证据支持“当时测试环境的基础回环也失败”，不支持“已确定 Docker/WSL 内部根因”，更不支持“五十节点通过”。

Mac 上先测独立 TCP/UDP 回环，再运行六、二十节点；资源允许时继续：

```sh
python3 scripts/test_lan_sync_sandboxes.py --nodes 50 --output artifacts/lan-sync-mac-containers-50.json --keep-on-failure
```

记录镜像摘要、宿主/虚拟化内核、资源限额、实际入组数、各节点错误、线程数和回环探针结果。使用原有断言；若失败先保留报告，再停止并仅清理该运行唯一前缀的容器/网络。不要为了压力测试重置用户 Docker、修改宿主网络或影响其他容器。Docker Desktop 容器仍共享虚拟化内核，不能当作多台独立 VM 的验收。

## 7. 记录与交付完成条件

每完成一项，在 [VALIDATION.md](../VALIDATION.md) 追加以下记录，并更新本文件对应勾选项和 [PR #3](https://github.com/asmoyou/rime-Q/pull/3)：

```text
日期 / 任务编号：
提交 / 包版本 / 构建号 / SHA-256：
机器、系统、架构、节点类型与数量：
网络拓扑 / 权限状态 / 本机词库是否隔离：
实际步骤与合成输入：
预期 / 实际 / 通过或失败：
证据文件 / 已确认问题 / 未确认推断：
数据保留与本任务资源清理结果：
```

只提交已筛选的合成测试摘要，不提交 `control.json`、配对码、密钥、真实学习库、完整环境或未经筛选的安装日志。截图、完整日志等大文件注明其存放位置与取得方式；不要留仅能在旧 Windows 机器上读取的唯一结论依据。

- [ ] M1–M4 的 Mac 必需验收完成，失败项得到修复并用原始场景复测。
- [ ] 六设备目标和实际参与硬件一致，缺少的系统/架构组合如实标注；五十节点及 P1 商用事项有通过证据或明确尚未完成，未完成时保持开发预览。
- [ ] 修改涉及的两端测试和目标提交 CI 通过；此前 0497a25 的成功不能替代后续代码提交。
- [ ] 更新最终 PR 范围、风险和证据，完成正式发布条件后继续既有交付流程：核对 main、统一标签/包版本、使用该次已验证产物发布及核对附件摘要和更新入口。版本发布授权按现有会话与 AGENTS.md 执行，不重复询问；这次纯交接文档提交不创建版本。

可直接交给 Mac 接手任务的说明：

> 请继续 `asmoyou/rime-Q` 的 `codex/lan-dictionary-sync` 分支和 PR #3。先读 AGENTS.md、本文件、docs/LAN_SYNC.md、docs/VALIDATION.md 与已提交的验证摘要。功能代码基线 0497a25 的完整 CI 已通过；六/二十节点和 Windows Sandbox 已有证据，Mac 原生同步适配、本地网络/Keychain 授权、六设备跨平台真机输入与网络切换尚未验收。按 M1–M4 优先补测试、修复并实际验证，再推进 P1 剩余工作；不要重新设计两设备配对、重复已完成工作或把容器结果当真机结果。用户已授权继续开发和实测，必要构建验证继续执行，系统认证由用户本人完成。保留个人数据，逐项记录事实与失败，达到完成条件再进入已有发布流程。
