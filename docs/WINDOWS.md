# Windows 客户端

Windows 客户端源码位于 `windows/`，使用原生 TSF 接入，独立进程运行 librime，设置使用 WPF。当前开发版本 **0.4.0**；安装包由本机或 CI 构建，尚未发布 Windows Release。系统级安装与外部宿主验收的实际状态见 [验证记录](VALIDATION.md)，不要将隔离测试等同于所有应用可用。

## 支持范围与功能

- 目标系统：Windows 10 22H2 / Windows 11 x64。包含 x64 和 x86 TSF DLL；Windows ARM64 原生宿主不在本包范围。
- 内置 librime 1.17.0、Lua、octagram、固定版本雾凇词库与 OpenCC 资源；预先编译词库，日常输入离线，无需安装其他输入法。
- 全拼预编辑、空格/数字/鼠标选词、翻页、取消、Shift 中英文切换及焦点处理。引擎未就绪、写锁被拒绝或连接失败时交回按键。
- 原生候选、六种配色、四档字号、栏外敲敲猫；按内容测量、屏幕边缘避让，尊重 Windows 透明度、高对比度和动画设置。
- WPF 设置采用与 macOS 对齐的分组、行式设置和深浅主题；独立皮肤页使用原版猫咪曲线，并与实际候选共用绘制模块。支持个人词库 TSV 编辑、可选模型、版本更新和离线帮助。
- 独立安装程序，读取实际已装版本/构建，拒绝降级，失败尝试回滚。程序按版本目录安装，避免覆盖宿主已加载的 DLL；卸载默认保留个人数据。

Windows 客户端使用 librime 原生排序与学习；根目录 C++ 实验核心及 `rimeq.exe demo` 仍为独立组件。当前未承诺 Windows Store/AppContainer、高权限应用、远程桌面和全部第三方编辑器兼容，这些场景必须分别验收。词表管理当前支持个人 TSV；macOS 的独立第三方方案编译/词表启停界面尚未移植，不支持 SCEL。

![Windows 皮肤页原生渲染](images/windows-skins.png)

## 构建

需要 Windows x64、Python 3.11+、CMake 3.21+、Visual Studio 2022 Build Tools（C++ x64/x86、Windows SDK、MSBuild），以及 Windows 自带的 .NET Framework 4.8。无需额外安装 .NET Desktop Runtime 或 VC 运行库。构建工具和依赖的首次获取需要联网。

```powershell
python scripts/build_windows.py --smoke
```

资源已完整构建后可用：

```powershell
python scripts/build_windows.py --reuse-resources --smoke
```

开发构建可加 `--no-package`；用 `--build N` 指定递增的 Windows 文件构建号，范围 1–65535。默认构建号见脚本。产物为 `dist/RimeQ-0.4.0-windows-x64.exe` 和对应 SHA256SUMS；`build-windows/stage` 是打包目录，不应直接注册为系统安装。

构建使用固定摘要下载运行库和解包工具，只提取 Weasel 分发包里的 OpenCC 数据，不安装、执行或注册 Weasel 程序。依赖见 [dependencies.lock.json](../dependencies.lock.json)；完整雾凇源码归档、运行库版本记录及许可随包提供。安装包不包含 `.gram` 模型。

## 安装与个人数据

安装目录为 `%ProgramFiles%\RimeQ`，版本目录在其 `versions` 下。原生 TSF 标识固定为：

- CLSID：`{C13A9B62-413B-45B8-9EF1-884522319760}`
- 简体中文 Profile：`{984DA75B-478E-49B4-9CB6-945CA5E7AD41}`，LANGID `0x0804`

双击安装包，确认 Windows 管理员认证。认证用于写入本产品目录和注册两种位数的输入服务；取消时不完成操作。安装后的用户启用和后台启动由原始桌面用户进程执行，不在管理员账户下创建用户词库。安装只启用 Rime Q，不将其强制设为默认输入法。

个人目录为 `%APPDATA%\RimeQ`，学习库位于 `rime`，可选模型位于 `models`。应用升级、修复和卸载均保留该目录。模型通过硬链接供输入引擎读取，不占两份空间，不依赖开发者模式。数据与小狼毫、RIMES、鼠须管及其他输入法隔离。

系统卸载入口、输入法菜单和通知区域菜单均提供卸载。只操作自己的标识与经路径检查的文件；宿主仍加载的旧 DLL 可能暂时保留。不能为测试卸载而删除用户现用输入法。

完整使用、备份、异常处理和手动卸载步骤见随包 [离线说明](../windows/resources/help/index.html)。

## 验证入口

`--smoke` 运行引擎/Lua/选词、跨进程个人词库学习、设置与更新/下载策略、安装版本/路径检查及 WPF 渲染。另可运行：

```powershell
python scripts/test_windows_client.py
```

该测试用生产 DLL 连接真实 TSF 文本上下文、组合与写锁，驱动测试专用按键/焦点事件，并连接隔离的 x64 librime；覆盖 x64/x86 客户端。它不注册系统输入法，不更改默认输入法，不向用户窗口发送按键；发现已有 Rime Q 服务时拒绝占用同名管道。此测试不能替代记事本、浏览器和编辑器中的真实输入验收。

`windows/tests/candidate_tests.cpp` 检查候选测量、长注释、鼠标索引、装饰尺寸/透传/隐藏和边缘避让，并渲染候选表面。输出位于忽略目录 `artifacts/windows-ui`。设置渲染也使用隔离偏好目录。构建 9122 新增五页、深浅主题、三种尺寸的 30 张渲染，以及皮肤/字号控件和动画停止检查。

已安装的构建 9121 在本机 x64/x86 RichEdit 宿主中通过了六组物理按键测试，具体结果见验证记录。构建 9122 已在本机完成升级，x64/x86 RichEdit 真实输入均通过，并确认实际加载的 TIP 为 0.4.0.9122。详见验证记录。

CI 的安装/修复/卸载步骤只在一次性运行机执行；个人数据保留与已装启用状态分别检查。本文不将尚未执行的 CI 或系统安装步骤列为通过。
