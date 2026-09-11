# Windows 开发交接

更新日期：2026-09-11。开发仓库为 [asmoyou/rime-Q](https://github.com/asmoyou/rime-Q)，从 `main` 开始。`v0.3.1` 是已发布的 macOS 版本；`main` 还包含发布后的模型存储清理和验证改动。

## 当前能够运行什么

| 部分 | 当前状态 |
| --- | --- |
| C++17 核心、SQLite 存储、命令行演示和回归测试 | 已有 Windows x64 CI 构建与测试 |
| macOS 客户端、设置、词库管理、可选模型下载与安装包 | 已实现，作为产品行为和引擎接入参考 |
| Windows TSF 接入、预编辑、候选窗、设置和安装器 | 尚未实现，需要在本仓库开发 |
| Windows librime 运行库、插件和资源打包 | 尚未配置；当前依赖锁中的运行库来自 macOS PKG |

核心库是实验性的个性化排序与学习库，尚未接入实际客户端。当前 macOS 客户端使用 librime 的原生候选和学习；`rimeq.exe demo` 只演示算法，不会注册输入法或提供中文输入界面。

已核验的代码基线是 `657b0f3c4ea7977eb051327c4486ed38558be7f9`：[CI 34550283791](https://github.com/asmoyou/rime-Q/actions/runs/34550283791) 的 Windows、Linux、macOS 核心任务及 macOS 打包任务均通过。交接前的 `a9979e3` 只比该基线多验证文档。Windows CI 使用 `windows-2022`，没有验证 Windows 桌面宿主中的真实输入。

## 在新电脑拉取

安装 Git，在 PowerShell 中执行：

```powershell
New-Item -ItemType Directory -Force C:\dev | Out-Null
Set-Location C:\dev
git clone --branch main https://github.com/asmoyou/rime-Q.git
Set-Location rime-Q
git status --short --branch
git log -1 --oneline
git switch -c feat/windows-client
```

已有副本时，在没有本地未提交改动的前提下，使用 `git switch main`、`git pull --ff-only origin main` 更新，再创建开发分支。公开仓库的拉取不需要令牌；之后推送开发分支时使用自己的 GitHub 登录。

## 先构建现有核心

建议先使用 Windows 11 x64 开发机，与现有 x64 核心构建保持一致。安装 Visual Studio 2022 或其 Build Tools，选择“使用 C++ 的桌面开发”、MSVC x64/x86 工具、Windows SDK 和 C++ CMake 工具。以下命令使用 Visual Studio 2022 Developer PowerShell，CMake 需支持 [Visual Studio 2022 生成器](https://cmake.org/cmake/help/latest/generator/Visual%20Studio%2017%202022.html)（3.21+）。Python 3.10+ 可留作后续资源脚本开发，现有核心构建不需要 Python 或 Swift。

如尚未安装独立的 vcpkg，在同一个 PowerShell 窗口执行：

```powershell
$rimeqVcpkg = 'C:\dev\vcpkg'
git clone https://github.com/microsoft/vcpkg.git $rimeqVcpkg
& "$rimeqVcpkg\bootstrap-vcpkg.bat"
& "$rimeqVcpkg\vcpkg.exe" install sqlite3:x64-windows
```

已有独立 vcpkg 时，将 `$rimeqVcpkg` 设为它的实际目录，跳过 clone 和 bootstrap，安装相同的 SQLite triplet。首次依赖安装需要联网。vcpkg 的获取和 CMake 工具链接入方式见 [Microsoft 文档](https://learn.microsoft.com/en-us/vcpkg/get_started/get-started)。

回到 Rime Q 仓库根目录：

```powershell
Set-Location C:\dev\rime-Q
cmake -S . -B build-windows -G "Visual Studio 17 2022" -A x64 "-DCMAKE_TOOLCHAIN_FILE=$rimeqVcpkg/scripts/buildsystems/vcpkg.cmake" -DVCPKG_TARGET_TRIPLET=x64-windows
cmake --build build-windows --config Release --parallel
ctest --test-dir build-windows -C Release --output-on-failure
& .\build-windows\Release\rimeq.exe demo
```

逐条确认退出码为 0，失败时先处理错误再执行下一条；PowerShell 的原生命令失败不一定自动停止后续命令。CTest 应通过 `core_regressions` 和 `demo` 两个入口，演示应显示学习前后排序及自造词召回。

这套配置使用与 [现有 CI](../.github/workflows/ci.yml) 相同的 x64 triplet、SQLite 依赖和 Release 构建。独立 vcpkg 的安装步骤仍需在新电脑执行确认；本次交接未在目标 Windows 电脑运行这些命令。当前核心依赖没有锁定 vcpkg/SQLite 版本，后续建立 Windows 构建时应记录并固定基线。

## 接手时先读这些文件

| 入口 | 用途 |
| --- | --- |
| [项目约定](../AGENTS.md)、[开发计划](PLAN.md) | 当前产品方向、数据边界和验收要求 |
| [架构说明](ARCHITECTURE.md)、[验证记录](VALIDATION.md) | 实验性核心与实际客户端的区别、已有证据和未完成项 |
| [核心头文件](../include/rimeq/core.hpp)、[核心实现](../src/core.cpp)、[存储实现](../src/database.cpp) | 可直接在 Windows 构建的 C++ 代码 |
| [引擎桥接](../macos/Bridge/QRimeBridge.cpp)、[接口](../macos/Bridge/include/QRimeBridge.h) | librime 会话、候选、提交和 levers 词库接口的参考 |
| [输入控制器](../macos/Sources/InputController.swift)、[引擎层](../macos/Sources/Engine.swift) | 按键、焦点、组合态和候选身份的现有处理 |
| [词库说明](DICTIONARIES.md)、[个人词库](../macos/Sources/PersonalDictionary.swift)、[资源管理](../macos/Sources/DictionaryResources.swift) | 个人学习记录、导入导出、后台编译与资源切换 |
| [可选模型](../macos/Sources/OptionalModel.swift)、[更新检查](../macos/Sources/UpdateChecker.swift) | 下载校验、取消/重试、跨版本保留及更新频率 |
| [输入方案](../data/rime_q.schema.yaml)、[依赖锁](../dependencies.lock.json)、[第三方声明](../THIRD_PARTY_NOTICES.md) | 资源来源、版本、校验和许可 |

`macos/Bridge/QRimeBridge.cpp` 使用 `dlopen` 和 `.dylib`，`scripts/prepare_resources.py` 使用 `pkgutil` 解包 Squirrel 的 macOS 运行库；这些实现不能直接在 Windows 使用。引入 Windows librime、Lua、octagram 和 OpenCC 资源时，需要新增对应的获取、校验、加载和部署流程，保留当前 macOS 构建。

## Windows 客户端的首个里程碑

先完成“安装开发构建后，能在真实应用输入简体全拼”的闭环，再扩展设置与皮肤。建议顺序如下，具体工程结构在实现时确定：

1. 确定 Windows librime 和插件的固定版本，使用隔离的 Rime Q 数据目录完成资源部署、基础输入、选词、学习与重启召回。
2. 实现 [Windows TSF](https://learn.microsoft.com/en-us/windows/win32/tsf/text-services-framework) 接入、独立注册标识、输入框会话与上屏。评估薄 TSF DLL 配合进程外引擎服务的方案，避免初始化或部署阻塞宿主按键；引擎未就绪或失效时不吞键。
3. 实现预编辑、候选显示和定位、空格/数字/鼠标选词、翻页、Esc 取消、Shift 中英切换和焦点变化。保持候选与实际提交动作一致，覆盖部分选词，不向旧输入框提交。
4. 在记事本、浏览器输入框和一个常用编辑器中验收首次切换后的首键、连续输入、焦点切换、重启和故障恢复，记录具体系统、应用版本和步骤。继续覆盖 DPI、多显示器及 x86 宿主；x64 核心通过不代表这些场景已通过。
5. 补齐安装、升级、修复和卸载保留数据，再迁移个人词库管理、可选模型、版本更新及原生设置。将构建、引擎和安装测试接入 CI，把真实宿主结果写入 [验证记录](VALIDATION.md)。

Windows 端继承当前产品行为：日常输入离线；默认每 24 小时检查 GitHub 发布信息，可关闭，不上传输入内容，也不自动下载安装。万象模型默认不下载，由用户主动下载并校验；已下载模型独立于程序安装，升级、重装和关闭优化均保留。用户数据必须与小狼毫、RIMES 和其他输入法隔离。

## Git 同步范围与历史参考

本仓库已经包含当前源码、方案覆盖文件、测试、构建脚本、CI、产品约定、验证摘要、依赖来源及许可。没有 Git 子模块，也不依赖原 Mac 工作区的兄弟目录；在 Windows 开始现有核心开发只需拉取本仓库并安装开发依赖。

`.cache/`、`vendor/`、`build*/`、`.build/`、`dist/`、`artifacts/` 和个人数据库按 [忽略规则](../.gitignore) 留在本机。它们包括下载缓存、生成产物、临时诊断脚本和原始日志。验证摘要已整理到仓库文档；引用的本机原始日志不会随 clone 下载。macOS 发布安装包与可选模型见 [Releases](https://github.com/asmoyou/rime-Q/releases)，Windows 的运行库获取和资源打包仍属于待实现内容。

原工作区外的《产品方向与首版范围》《RIMES项目评估》《本机测试说明》属于早期评估或旧项目测试，其中更新策略、安装路径等已不适用于当前版本；当前决策以本仓库的项目约定和文档为准。

早期 Windows 平台接入参考可从 [RIMES 固定基线的原生 Windows 文档](https://github.com/scholay/rimes/blob/eba5185a3ed637b6df9ca9149fbfc49740bd58b2/platforms/windows/native/README.md) 获取。它属于其他项目，尚未导入 Rime Q；其中的验证记录也不代表 Rime Q 的 Windows 验证结果。实际复用时按 [第三方声明](../THIRD_PARTY_NOTICES.md) 的方式记录来源与许可，并使用 Rime Q 自己的产品标识和数据路径。
