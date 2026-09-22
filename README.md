# Rime Q

**简洁、流畅、离线的中文输入法。**

基于 Rime 引擎，内置雾凇词库，万象语法模型可按需下载。熟悉的全拼输入，清晰的原生候选栏，再加上一只陪你敲键盘的小猫。

[下载 Windows 版](https://github.com/asmoyou/rime-Q/releases/latest) · [下载 macOS 版](https://github.com/asmoyou/rime-Q/releases/latest) · [版本记录](https://github.com/asmoyou/rime-Q/releases) · [反馈问题](https://github.com/asmoyou/rime-Q/issues)

[![Release](https://img.shields.io/github/v/release/asmoyou/rime-Q?label=Release)](https://github.com/asmoyou/rime-Q/releases/latest)
[![Build and test](https://github.com/asmoyou/rime-Q/actions/workflows/ci.yml/badge.svg)](https://github.com/asmoyou/rime-Q/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-GPL--3.0--only-blue)](LICENSE)

![Rime Q macOS 设置与原生候选预览](docs/images/settings.png)

## 为日常中文输入而做

- **装好就能输入。** 安装包包含引擎和基础词库，无需另外安装其他输入法。支持简体全拼、空格与数字选词、鼠标选词、翻页和中英文切换。
- **输入留在本机。** 组词、候选和个人学习都在本地完成，断网也可以打字。更新检查只查询 GitHub 发布信息，不发送输入内容或个人词库。
- **按自己的习惯调整。** 原生候选栏按内容收紧宽度，支持四档字号、六款简洁配色与系统深浅外观；可选万象语法模型辅助整句组词。
- **让词库更贴合自己。** 搜索、编辑和导入导出个人学习记录；管理内置词表，导入带全拼编码的第三方词库，查看资源来源与许可。
- **常用工具，随手就有。** 在输入框里获取日期、时间、农历，计算表达式，转换金额大写，或输入 Unicode 字符。
- **升级时保留积累。** 安装器识别升级与同版本，保留个人词库和设置，避免重复覆盖并阻止旧包覆盖新版。默认每天检查一次更新，可随时关闭。

## 下载与安装

| 平台 | 当前支持情况 |
| --- | --- |
| macOS 13 及更新版本 | 已提供 PKG；同一安装包支持 Apple Silicon 与 Intel |
| Windows 10 22H2 / Windows 11 x64 | 独立 EXE 安装包，含 x64/x86 TSF；安装与宿主验收状态见 [Windows 说明](docs/WINDOWS.md) |
| Linux | 客户端规划中 |

Windows：前往 [最新版本](https://github.com/asmoyou/rime-Q/releases/latest)，下载 `RimeQ-0.4.7-windows-x64.exe`。双击安装并完成管理员认证，然后在输入法列表选择 **Rime Q**。安装、升级和备份步骤见 [Windows 使用说明](docs/WINDOWS.md)。Windows 安装包尚未进行 Authenticode 签名。

macOS：

1. 前往 [最新版本](https://github.com/asmoyou/rime-Q/releases/latest)，下载 `RimeQ-0.4.7-macos-universal.pkg`。
2. 双击安装包，按 macOS 安装器的提示完成安装。应用会安装到系统输入法目录，并在后台完成启用。
3. 从菜单栏的输入法菜单选择 **Rime Q**，开始输入。

当前发布版 **[0.4.7](https://github.com/asmoyou/rime-Q/releases/tag/v0.4.7)** 减少双平台同步的后台轮询和重复词库处理；Windows 设置窗口按需创建、关闭后释放页面，并优化附近设备页布局，避免短暂连接提示反复出现引起页面抖动。升级保留原同步组与个人记录。性能样本与实际验收范围见 [验证记录](docs/VALIDATION.md)。

macOS 安装包已做本地 ad-hoc 签名，尚未完成 Apple Developer ID 签名与公证。若 macOS 阻止打开，请确认文件来自本项目，再按“系统设置 → 隐私与安全性”的提示处理（[Apple 说明](https://support.apple.com/zh-cn/102445)）。macOS 实际宿主测试主要在 Intel Mac 上完成，通用包构建通过不代表全部 Apple Silicon 宿主均已验证。

安装时，管理员认证用于写入系统输入法目录；安装器可能请求读取下载文件夹。升级较早版本时，也可能请求退出仍在运行的旧版 Rime Q。详见 [安装与授权说明](docs/PERMISSIONS.md)。

安装成功后通常可以直接切换使用。若未启用，应用会说明当前状态，并提供稍后处理、键盘设置和下次登录重试入口。排查步骤见 [Mac 使用说明](docs/MACOS.md)。

## 打字与快捷输入

| 按键 | 用途 |
| --- | --- |
| 空格 | 确认当前候选 |
| 数字键 / 鼠标 | 选择对应候选 |
| 单独按下并松开 Shift | 切换中英文 |
| Caps Lock（Mac） | 锁定大写，解除后恢复原输入模式 |
| `−` / `=` 或 Page Up / Page Down | 候选翻页 |
| Esc | 取消当前组合 |
| `[` / `]` | 取当前候选的首字 / 尾字 |

“设置 → 输入与外观 → 拼音纠错”提供默认开启的相邻键容错和正确拼音提示。例如 `nihso` 可找到 `你好（ni hao）`，`zhognguo` 可得到 `中国（zhong guo）`。完全离线，注释不上屏；选项在当前输入结束后生效。关闭相邻键容错仍保留基础拼写规则，关闭提示只隐藏注释。纠错不保证目标词排在首位。

Mac 保留原来的单个 Rime Q 输入源和 Q 图标，输入时另用“中 / A”状态按钮显示当前模式。单独按下并松开 Shift，或点按状态按钮，即可切换。可按住 Command 将状态按钮拖到系统输入法图标左侧，位置由 macOS 保存。想减少占用，可在系统输入法菜单选择“隐藏输入法名称”，使用“中 Q / A Q”的紧凑布局。

以下触发码在中文模式下使用，区分大小写；出现结果后，空格或数字键选取。

| 输入 | 结果 |
| --- | --- |
| `rq` / `sj` / `xq` | 当前日期 / 时间 / 星期 |
| `nl` | 今日农历 |
| `cC1+2*3` | 计算结果 `7` |
| `R123.45` | 数字与金额大写 |
| `U62fc` | Unicode 字符“拼” |
| `uuid` | 随机 UUID |

完整用法也可从输入法菜单的 **使用说明** 打开，无需联网。

## 选一款舒服的皮肤

![Rime Q macOS 皮肤：敲敲猫与六款简洁配色](docs/images/skins.png)

“随系统”使用原生半透明材质，另有纸白、雾蓝、青玉、浅樱、暮色五款配色。选择即保存，下一次输入时生效；可在设置中预览 16、18、20、22 磅候选字号。

**敲敲猫** 趴在候选栏上边缘外侧，随按键交替敲击，停笔后安静休息。它不占候选内容空间，也不拦截选词。开启系统“减少动态效果”后保持静止；“随系统”配色同时遵循“减少透明度”。

## 词库与整句优化

**个人词库** 管理自己的学习记录，支持搜索、排序、新增、编辑、删除、撤销和 UTF-8 TSV 导入导出。删除个人记录后，内置词库中的同名词仍可能出现。

提供默认关闭的 **附近设备同步**：每台电脑加入一次，在局域网内合并个人词条与学习权重，支持多设备接力和离线补齐。实现范围、操作和测试边界见 [附近设备同步说明](docs/LAN_SYNC.md)。

同步以减少后台消耗为先，不追求实时：本机词库停止变化约 60 秒后再合并；持续变化时约每 5 分钟安排一次，仍等待当前拼音组合结束。空闲设备间隔约 30 秒联系一次，多设备接力可能需要几分钟。手动同步可跳过上述合并等待；远端变化和未完成任务会及时处理，同样不打断当前组合输入。

**词库与模型** 展示内置资源的来源、版本与许可，可以启停可选词表，导入独立的全拼 `.dict.yaml` 或 TSV/TXT 词表。编译在后台进行，成功后等当前输入结束再切换，失败时继续使用原词库。当前不支持直接导入 SCEL、双拼、形码或完整输入方案包。格式和限制见 [词库说明](docs/DICTIONARIES.md)。

**整句优化** 通过万象语法模型辅助连续输入中的同音字词选择，默认关闭。需要时进入“设置 → 输入与外观”，点击 **下载并开启**，下载约 420 MB 的模型。页面显示进度，支持取消与失败重试；文件校验通过后启用，之后可以离线使用。也可移除模型释放空间，基础组词和学习记录保留。

开启与关闭共用雾凇词库和个人学习记录，效果取决于输入内容。按 0.3.1 及后续版本下载的模型保存在个人数据目录，独立于应用安装包；升级或重装 Rime Q 会保留它，关闭整句优化也不会删除模型。同一模型版本只需下载一次，启动时在本地校验后复用。

模型保存在个人数据目录的 `models/wanxiang-lts-zh-hans.gram`：macOS 根目录为 `~/Library/Application Support/RimeQ`，Windows 为 `%APPDATA%\RimeQ`。`rime` 目录通过链接读取模型，Windows 使用硬链接，不额外占用一份模型空间。只有主动移除、文件缺失或损坏，或之后选择升级模型本身时，才需要重新下载；普通软件升级不会触发模型下载。

## 更新、备份与卸载

![Rime Q macOS 版本与更新设置](docs/images/updates.png)

进入 **设置 → 版本与更新**，可查看当前版本、构建号和检查结果。自动检查默认开启，每 24 小时最多一次，重启应用也保留间隔；断网或请求失败会等待下一周期。发现新版时，输入法菜单和设置入口会显示提示，后台检查不会弹窗打断输入。

可以关闭自动检查，也可以随时使用 **检查更新…**。应用区分新版本、没有更新、尚无公开版本和请求失败。下载与安装由你决定，不会自动下载安装包。

个人数据目录如下，输入法菜单可以直接打开：

| 平台 | 个人数据目录 |
| --- | --- |
| macOS | `~/Library/Application Support/RimeQ` |
| Windows | `%APPDATA%\RimeQ` |

其中 `rime` 保存输入配置和学习词库，`dictionaries` 保存第三方词库和管理配置，`models` 保存可选下载的模型。迁移个人词条时，建议从设置导出 TSV，在另一台机器导入。

从菜单选择 **卸载 Rime Q…** 可停用并移除应用，个人词库与学习记录默认保留。Windows 也可从系统已安装应用列表卸载。数据备份和手动卸载步骤见 [Mac 使用说明](docs/MACOS.md) 与 [Windows 使用说明](docs/WINDOWS.md)。

## 从源码构建

Windows 客户端构建：`python scripts/build_windows.py --smoke`，产物为 `dist/RimeQ-0.4.7-windows-x64.exe`。原生 TSF、独立引擎服务、WPF 设置、个人词库、词库资源、可选模型及安装步骤见 [Windows 说明](docs/WINDOWS.md)。macOS 与 Windows 使用相同的设置页能力、词库与模型规则及操作流程，系统输入接入和原生控件分别适配；一致性契约见 [客户端功能一致性](docs/CLIENT_PARITY.md)。

macOS 客户端构建需要 macOS 13+、Xcode 工具链和 Python 3.10+。首次构建会下载并核验固定版本依赖。

```sh
git clone https://github.com/asmoyou/rime-Q.git
cd rime-Q
python3 scripts/build_macos.py --universal --smoke
```

产物为 `dist/RimeQ-0.4.7-macos-universal.pkg`。已有资源缓存时可加 `--reuse-resources`；默认只保留 PKG，临时应用在打包后清理。

构建检查包括真实引擎与学习、快捷输入、词库管理、原生设置操作、候选皮肤、安装状态、更新版本比较和每日调度。CI 还会在独立运行环境安装实际 PKG，核验启用或明确的待启用处理，并验证卸载保留数据。

[验证记录](docs/VALIDATION.md) · [架构说明](docs/ARCHITECTURE.md) · [开发计划](docs/PLAN.md)

## 反馈与贡献

欢迎通过 [Issues](https://github.com/asmoyou/rime-Q/issues) 反馈问题或提出建议。报告输入或安装问题时，请附上 Rime Q 版本与构建号、操作系统及版本、处理器架构、出现问题的应用和可复现步骤。示例输入与日志请先移除私人信息。

## 致谢与许可

感谢 [Rime](https://github.com/rime/librime)、[雾凇拼音](https://github.com/iDvel/rime-ice)、[万象](https://github.com/amzxyz/rime_wanxiang) 及相关资源作者。

自有代码采用 [GPL-3.0-only](LICENSE)。第三方代码、词库和模型保留各自许可，来源、固定版本与校验信息见 [第三方声明](THIRD_PARTY_NOTICES.md) 和 [依赖锁定文件](dependencies.lock.json)。
