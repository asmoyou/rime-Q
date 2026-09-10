# Rime Q

简洁、流畅、离线的中文输入法。

基于 librime，吸收雾凇词库与万象语法模型，独立开发输入界面和体验。安装包内置引擎与资源，不需要另装鼠须管。

当前先验证 macOS，Windows、Linux 客户端在后续计划中。Mac 开发预览提供简体全拼、候选选择、中英文切换与可选长句优化；还不是正式发行版。

## Mac 开发预览

需要 macOS 13+、Xcode 和 Python 3.9+。

安装授权用途：管理员认证用于安装到系统输入法目录；“安装器访问下载文件夹”用于读取安装包；升级时“控制 Rime Q”用于退出旧版进程。[详细授权说明](docs/PERMISSIONS.md)

```sh
python3 scripts/build_macos.py --universal --smoke
```

双击产物 `dist/RimeQ-0.1.4-preview.pkg` 安装，包含 Intel 与 Apple Silicon 程序。安装后在后台自动启用，完成后即可从菜单选择 **Rime Q**。只有启用未通过时才显示提示，提供稍后处理或注销选项，并安排下次登录重试。

输入法菜单提供设置、使用说明、检查更新和卸载。更新检查由用户主动触发，卸载默认保留个人词库。

构建会获取固定版本依赖；安装后的日常输入完全离线。当前预览未做 Developer ID 签名与公证。[测试与安装说明](docs/MACOS.md)

## 验证

```sh
# 真实引擎：组词、选词、重启学习、模式切换和会话隔离
'/Library/Input Methods/RimeQ.app/Contents/MacOS/RimeQ' --smoke
'/Library/Input Methods/RimeQ.app/Contents/MacOS/RimeQ' --benchmark

# 尚未接入客户端的实验性排序库
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
(cd build && ctest --output-on-failure)
./build/rimeq demo
```

[开发计划](docs/PLAN.md) · [架构](docs/ARCHITECTURE.md) · [词库策略](docs/DICTIONARIES.md) · [第三方来源](THIRD_PARTY_NOTICES.md)

参考 [RIMES](https://github.com/scholay/rimes) 的平台接入经验。自有代码采用 GPL-3.0-only，第三方资源保留各自许可。
