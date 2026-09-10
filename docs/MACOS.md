# Mac 开发预览

需要 macOS 13 或更新版本。`--universal` 构建同时包含 Intel 与 Apple Silicon；目前实际测试机器为 Intel Mac。

## 安装

构建得到 `dist/RimeQ-0.1.2-preview.pkg`，双击即可安装应用与其内置的引擎、词库和模型。系统安装位置固定为 `/Library/Input Methods/RimeQ.app`，禁用 Installer 的应用重定位。安装后由 LaunchServices 启动当前登录用户的应用来注册输入法，再通过独立进程核验启用状态；不从包脚本直接执行注册入口。更新时会正常退出旧版本进程。

默认构建只保留 PKG，临时应用目录在打包后删除，避免重复应用影响系统识别。本地开发可用 `python3 scripts/build_macos.py --keep-app` 保留应用，再运行 `python3 scripts/install_macos.py`，将其移动到当前用户的 `~/Library/Input Methods/RimeQ.app`。两个安装位置只保留一份 Rime Q；PKG 遇到另一个安装目录内的同标识应用会在写入前中止，不自动删除个人文件。

安装后自动打开的 Rime Q 窗口显示真实启用结果。“已启用”可以从菜单栏切换，不需要注销或重启。“已安装，尚未启用”提供“稍后处理”“注销账户…”和“打开键盘设置”；默认选择稍后处理。注销按钮只请求系统的正常确认，不强制结束用户会话。失败时在用户 LaunchAgents 目录安排下次登录重试一次，再次失败后移除重试任务，避免循环打扰。

这是未完成 Developer ID 签名与公证的本地开发预览。面向普通用户的正式发布、更新和卸载流程仍在开发计划中。

## 使用

- 输入全拼，按空格确认当前候选；数字键或鼠标选择对应候选。
- `−` / `=` 或 Page Up / Page Down 翻页，Esc 取消当前组合。
- 单独按下并松开 Shift 切换中英文。
- 输入法菜单的“设置”提供基础输入/万象长句优化和候选字号。
- “使用说明”打开随包的离线帮助，包含安装、更新、词库位置和手动卸载步骤。
- “检查更新…”仅在点击后查询 GitHub 最新公开发布版本，不自动下载或安装；没有公开版本、无法联网与已是最新分别提示。
- “卸载 Rime Q…”先确认、切换输入法并停用自己的输入源，再移除应用；系统目录的安装需要 macOS 管理员认证。取消认证时尝试恢复原来的输入源。个人词库始终保留。

手动卸载：先在键盘设置移除 Rime Q，再将 `/Library/Input Methods/RimeQ.app` 移到废纸篓；开发安装使用 `~/Library/Input Methods/RimeQ.app`。若存在 `~/Library/LaunchAgents/com.asmoyou.rimeq.activation.plist`，一并移除以取消自动重试。个人数据在 `~/Library/Application Support/RimeQ`，不会随应用卸载删除。

个人学习库在 `~/Library/Application Support/RimeQ/rime`，不读取鼠须管或 RIMES 的用户库。更换输入模式仍使用同一份 Q 学习库。

## 自动验证

```sh
'/Library/Input Methods/RimeQ.app/Contents/MacOS/RimeQ' --smoke
'/Library/Input Methods/RimeQ.app/Contents/MacOS/RimeQ' --benchmark
'/Library/Input Methods/RimeQ.app/Contents/MacOS/RimeQ' --render /tmp/rimeq-candidates.png
```

开发安装后，应将上述命令路径替换为 `~/Library/Input Methods/RimeQ.app/Contents/MacOS/RimeQ`。

构建会检查成品 PKG 中的安装路径、禁止重定位规则以及 LaunchServices 安装入口。安装状态与登录重试测试使用临时目录，不修改当前输入源。CI 实际执行 PKG 安装、核验启用、从系统目录运行引擎测试，并检查卸载后个人数据仍在。

引擎测试使用独立临时目录，分两个进程验证基础转换、逐字组词、学习、重启后的召回、模式切换与多会话隔离。性能测试使用合成输入，只统计引擎处理和候选快照，不包含 IMK 和绘制。

## 真实应用验收

在独立空白文档中验证：普通输入与标点、数字与鼠标选词、翻页、删除和取消、光标移动、中英文切换、组合中切换窗口，以及多屏幕候选位置。TextEdit、浏览器、Electron 应用和终端需要分别验收；引擎测试或候选截图不能代替这些检查。

目前尚未完成所有真实应用、异常退出、系统更新和正式安装流程的验证。测试结果记录在 [验证记录](VALIDATION.md)。
