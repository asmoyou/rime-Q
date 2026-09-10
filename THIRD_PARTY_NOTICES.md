# 第三方说明

Rime Q 自有代码按 GPL-3.0-only 发布，完整许可证见根目录 `LICENSE`。下列组件保留原许可证和作者信息；本项目的许可证不替代第三方许可。

| 组件 | 用途与来源 | 许可 |
| --- | --- | --- |
| librime 1.16.0 | 来自 Squirrel 1.1.2 官方安装包的运行库，源码基线 `a251145d3aafa33871824a40bbec04c966bd8b56` | BSD-3-Clause |
| librime C API 头文件 | 1.17.0，`33e78140250125871856cdc5b42ddc6a5fcd3cd4`，运行时检查可用 API | BSD-3-Clause |
| librime levers API 头文件 | 与运行库对应的 `a251145d3aafa33871824a40bbec04c966bd8b56`，用于个人学习词库维护；地址和校验值在依赖锁文件中 | BSD-3-Clause |
| [librime-lua](https://github.com/hchunhui/librime-lua) | Squirrel 1.1.2 随附的 Lua 插件 | BSD-3-Clause；Lua 保留其 MIT 许可 |
| [librime-octagram](https://github.com/lotem/librime-octagram) | Squirrel 1.1.2 随附的语法插件；保留上游 LICENSE | BSD-3-Clause |
| [雾凇拼音](https://github.com/iDvel/rime-ice) | 固定版本词库、输入规则、Lua 与 OpenCC 映射；Q 的方案通过 include 派生并裁剪扩展 | GPL-3.0-only，子组件另有声明时保留原声明 |
| [万象语法模型](https://github.com/amzxyz/RIME-LMDG) | `wanxiang-lts-zh-hans.gram`，作者 amzxyz；模型原样使用 | CC-BY-4.0 |
| [SQLite](https://www.sqlite.org/copyright.html) | 实验性核心库链接开发环境的 SQLite；Mac 客户端目前使用 librime 原生学习库 | Public domain |

运行库包、雾凇源码和万象模型的下载地址、字节校验值见 `dependencies.lock.json`。运行库经过本地 ad-hoc 重签名，内容校验在重签名前进行。雾凇的完整固定版本源码归档随应用放在 `Contents/Resources/Licenses/rime-ice-source.tar.gz`，所用配置、Lua 和词典源码也随包保留。

雾凇词库包含维护者整理的腾讯词向量词表及其他来源，词典文件头中的来源、作者与使用说明一并保留。新增来源需要记录版本、原始声明及转换过程。当前没有额外抓取商业输入法的封闭词库。

模型来自万象 LTS 发布资源，作者 amzxyz，原样使用。0.3.0 固定上游资产 `554955439`（2026-09-11 核验），并在本项目同版 Release 保留原文件副本；原始来源、字节数、SHA-256 和 CC-BY-4.0 许可校验均写入依赖锁。构建优先使用本项目固定版本副本，上游为备用来源；每个来源都必须通过相同的校验，不会自动接受上游替换后的其他内容。Q 的模型参数参考雾凇 `others/recipes/grammar.recipe.yaml`。

[RIMES](https://github.com/scholay/rimes) 的输入源安装器已复用并适配：`macos/Sources/InputSourceInstaller.swift` 取自提交 `eba5185a3ed637b6df9ca9149fbfc49740bd58b2`，保留注册、父子输入源启用、独立进程验证与有限重试。修改了命令命名空间并使自动选择可选。原作者 scholay 的 MIT 许可证保留在 `third_party/rimes/LICENSE` 并随安装包分发。安装脚本也参考其单份应用与重复注册处理原则；没有复制其图标或整套产品。

0.3.0 为首个公开版本。运行库保留 Squirrel 1.1.2 包内的第三方声明；所用 librime、Lua 与 octagram 的来源和许可如上。包内包含雾凇的固定版本源码。应用采用 ad-hoc 签名，Developer ID 签名、公证及更多目标系统验收仍待完成，范围见 `docs/VALIDATION.md`。
