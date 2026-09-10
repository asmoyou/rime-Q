# Mac 开发预览

需要 macOS 13 或更新版本。`--universal` 构建同时包含 Intel 与 Apple Silicon；目前实际测试机器为 Intel Mac。

## 安装

构建得到 `dist/RimeQ-0.1.1-preview.pkg`，双击即可安装应用与其内置的引擎、词库和模型。系统安装位置固定为 `/Library/Input Methods/RimeQ.app`，禁用 Installer 的应用重定位。安装后校验实际应用，再以当前登录用户的身份和图形会话执行注册，并通过独立进程核验启用状态。

默认构建只保留 PKG，临时应用目录在打包后删除，避免重复应用影响系统识别。本地开发可用 `python3 scripts/build_macos.py --keep-app` 保留应用，再运行 `python3 scripts/install_macos.py`，将其移动到当前用户的 `~/Library/Input Methods/RimeQ.app`。两个安装位置只保留一份 Rime Q；PKG 遇到另一个安装目录内的同标识应用会在写入前中止，不自动删除个人文件。

在“系统设置 → 键盘 → 文本输入 → 编辑 → ＋”添加 Rime Q，然后从菜单栏切换。macOS 首次注册新的输入法有时需要注销并重新登录才能真正激活；“已注册”不等于“已经可以选中”。

这是未完成 Developer ID 签名与公证的本地开发预览。面向普通用户的正式发布、更新和卸载流程仍在开发计划中。

## 使用

- 输入全拼，按空格确认当前候选；数字键或鼠标选择对应候选。
- `−` / `=` 或 Page Up / Page Down 翻页，Esc 取消当前组合。
- 单独按下并松开 Shift 切换中英文。
- 输入法菜单的“设置”提供基础输入/万象长句优化和候选字号。

个人学习库在 `~/Library/Application Support/RimeQ/rime`，不读取鼠须管或 RIMES 的用户库。更换输入模式仍使用同一份 Q 学习库。

## 自动验证

```sh
'/Library/Input Methods/RimeQ.app/Contents/MacOS/RimeQ' --smoke
'/Library/Input Methods/RimeQ.app/Contents/MacOS/RimeQ' --benchmark
'/Library/Input Methods/RimeQ.app/Contents/MacOS/RimeQ' --render /tmp/rimeq-candidates.png
```

开发安装后，应将上述命令路径替换为 `~/Library/Input Methods/RimeQ.app/Contents/MacOS/RimeQ`。

构建会检查成品 PKG 中的安装路径、禁止重定位规则以及前后安装脚本。CI 还实际执行 PKG 安装，并从固定系统目录运行引擎测试；不能仅凭打包成功认定安装成功。

引擎测试使用独立临时目录，分两个进程验证基础转换、逐字组词、学习、重启后的召回、模式切换与多会话隔离。性能测试使用合成输入，只统计引擎处理和候选快照，不包含 IMK 和绘制。

## 真实应用验收

在独立空白文档中验证：普通输入与标点、数字与鼠标选词、翻页、删除和取消、光标移动、中英文切换、组合中切换窗口，以及多屏幕候选位置。TextEdit、浏览器、Electron 应用和终端需要分别验收；引擎测试或候选截图不能代替这些检查。

目前尚未完成所有真实应用、异常退出、系统更新和正式安装流程的验证。测试结果记录在 [验证记录](VALIDATION.md)。
