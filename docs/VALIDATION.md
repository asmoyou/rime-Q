# 验证记录

日期：2026-09-10。机器：MacBookPro15,1，Intel Core i7-8850H 2.60 GHz，16 GB 内存，macOS 15.7.9。构建工具：Xcode，Swift 6.2.1；Release 配置。

## 已通过

- C++ 核心：9 组回归覆盖原始排序、引擎候选身份、新词召回、方案隔离、音节边界、完整/前缀动作、置顶与容量、非法数据、保存恢复和失败事务回滚。CTest 的核心与演示两个入口通过。
- Mac：Intel 与 Apple Silicon 通用程序构建通过；随包的三个运行库同样为通用二进制。代码签名结构检查通过，签名为本地 ad-hoc。
- 完整应用内的 librime 1.16.0 测试：普通转换、逐字组合“青岚松鼠测词”、首屏召回、独立进程重启后召回、常用单字进入首屏、切换万象模式保留学习、双会话隔离。
- 原生候选视图已渲染并目视检查。输入会话测试通过预编辑、空格上屏、鼠标选词、取消、候选窗归属和同步焦点切换检查；测试使用模拟客户端，不能代替真实应用验收。
- 已生成自包含 PKG，并曾以开发脚本安装到当前用户的 Input Methods 目录；为排查空白输入源条目，当前已移除该安装，保留安装包和应用归档。未用 Installer.app 完整走一遍 PKG 安装流程。

## 性能基线

| 范围 | 样本 | p50 | p95 | p99 |
| --- | --- | ---: | ---: | ---: |
| 基础模式：逐键处理 + 候选快照 | 3,410 次 | 0.375 ms | 1.759 ms | 2.286 ms |
| 万象模式：逐键处理 + 候选快照 | 3,410 次 | 0.379 ms | 2.239 ms | 2.815 ms |
| 实验性个性化排序：5 万条学习记录、64 候选 | 20,000 次 | 44.090 μs | 65.832 μs | 109.160 μs |

启动初始化一次测得 280.9 ms，使用预编译词库，文件系统缓存未清空，不能称为冷启动指标。逐键测试排除了前 5 轮预热，使用 5 个合成输入，计时包含候选快照复制，不包含 IMK、UI 绘制或磁盘保存。实验性排序库尚未接入客户端，其结果单独列示。

内存、空闲 CPU、唤醒次数和真实应用端到端延迟尚未完成正式测量。当前基线不能证明已经优于其他输入法。

## 当前阻碍与残留排查

2026-09-10 后续排查：用户确认顶部灰色 RIMES 已消失。`com.apple.inputsources` 域的 `AppleEnabledThirdPartyInputSources` 仍保存 `com.isaac.inputmethod.RimeBuffer` 的父级和 Hans 模式两条记录，以及鼠须管的两条记录。旧记录与空白行的因果关系尚未确认，不能把发现旧配置当成根因已定位。

macOS 的 cfprefsd 日志拒绝 Swift/`defaults` 进程写入该键，提示缺少 `user-preference-write` 或 `file-write-data` sandbox access。用户在 Terminal 运行同一修复脚本也未保存成功；管理员认证后的写入仍失败。因此限制不能仅归因于工具进程，不能把 TIS/defaults 返回成功当成已启用或已删除。

设置备份保留在本机忽略目录 `artifacts/input-source-repair`。已停用无效的 `清理旧RIMES.command`，不再要求用户重复运行；旧配置记录仍未清除。

Rime Q 先前移到 `.payload` 路径后仍被 LaunchServices 识别，单独改后缀不足以取消应用注册。现已保存 TAR 归档，并经 Finder 认证将原目录移入废纸篓，未清空废纸篓。Input Methods 两个安装目录和 LaunchServices 查询中均无 RIMES 或 Rime Q；鼠须管及全部个人词库保留。临时元数据恢复辅助应用未解决问题，已取消注册并删除。

界面复核：空白行位于“添加输入法”的简体中文可选列表，当前启用列表未见空白行。通过 LaunchServices 在实际登录会话启动只读诊断程序，分别读取默认语言及简体中文的 TIS 列表：313 个条目中没有空名称，也没有 RIMES 或 Rime Q 标识。诊断应用已移除，快照保留在本机排查目录。注册列表与设置界面不一致，具体原因仍未确定。

重新打开系统设置以及此前刷新 imklaunchagent/TextInputMenuAgent 后，空白行仍在。尝试 `launchctl kickstart -k gui/501/com.apple.TextInputSwitcher` 返回 150，提示系统完整性保护禁止该操作；未关闭保护或继续强制操作。用户随后重启，确认空白行消失；重启后旧 RIMES 的两条配置记录仍在。因此空白行与会话状态有关的可能性较高，不能据此认定旧配置已删除，也不能把旧配置直接当成空白行来源。

## PKG 安装位置故障

已从 `/var/log/install.log` 定位独立的安装包错误：2026-09-10 16:44:51，Installer 将 `Library/Input Methods/RimeQ.app` 重定位到先前的 `artifacts/input-source-repair/RimeQ-disabled-1789029178.payload`。旧 0.1.0 包的 `PackageInfo` 含 `<relocate><bundle id="com.asmoyou.inputmethod.RimeQ"/></relocate>`，且无 postinstall 注册脚本。这解释了安装器报告成功、系统安装目录却无应用，以及该排查目录变为 root 所有的现象。

0.1.1 改为固定系统路径、禁用应用重定位，增加重复安装检查、实际载荷签名校验及登录用户注册与独立进程核验；安装完成页说明启用步骤。默认打包结束后删除临时应用，只保留 PKG。成品包检查能拒绝旧包的重定位规则，并已通过新包检查；通用构建与随包引擎的学习、重启召回测试通过。CI 增加执行真正 PKG 安装、从系统安装目录运行引擎测试的步骤。

当前没有在真实宿主应用完成 Rime Q 打字验收。Windows 和 Linux 客户端尚未实现；三平台核心测试与 Mac 通用包构建、引擎回归已通过 GitHub Actions（首个提交 `960a4b2`）。
