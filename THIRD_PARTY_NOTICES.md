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

模型来自万象 LTS 发布资源，作者 amzxyz，原样使用。0.3.1 起不随安装包内置，仅在用户主动下载后使用，许可说明仍随应用保留。0.3.0 固定上游资产 `554955439`（2026-09-11 核验），并在本项目同版 Release 保留原文件副本；原始来源、字节数、SHA-256 和 CC-BY-4.0 许可校验均写入依赖锁。模型下载使用本项目固定版本副本，并校验锁定的大小及 SHA-256，不会自动接受上游替换后的其他内容。常规构建只打包模型描述信息及许可，不下载模型文件。Q 的模型参数参考雾凇 `others/recipes/grammar.recipe.yaml`。

[RIMES](https://github.com/scholay/rimes) 的输入源安装器已复用并适配：`macos/Sources/InputSourceInstaller.swift` 取自提交 `eba5185a3ed637b6df9ca9149fbfc49740bd58b2`，保留注册、父子输入源启用、独立进程验证与有限重试。修改了命令命名空间并使自动选择可选。原作者 scholay 的 MIT 许可证保留在 `third_party/rimes/LICENSE` 并随安装包分发。安装脚本也参考其单份应用与重复注册处理原则；没有复制其图标或整套产品。

0.3.0 为首个公开版本。运行库保留 Squirrel 1.1.2 包内的第三方声明；所用 librime、Lua 与 octagram 的来源和许可如上。包内包含雾凇的固定版本源码。应用采用 ad-hoc 签名，Developer ID 签名、公证及更多目标系统验收仍待完成，范围见 `docs/VALIDATION.md`。

## Windows 客户端

Windows 使用 librime 1.17.0 官方 MSVC x64 分发包，固定源码基线 `33e78140250125871856cdc5b42ddc6a5fcd3cd4`。该 DLL 静态集成 Lua、octagram 和 predict；上游随包版本记录分别为 `ec52e48`、`dfcc151`、`920bd41`，保留在安装目录的 `licenses/windows-runtime-version-info.txt`。Rime Q 使用 Lua 和 octagram，不启用 predict 预测模块。二进制中的 Lua 版本标识为 5.4.8，其官方源码归档摘要记录在依赖锁中，原始包含 MIT 许可的 README 随包保留。

基础 OpenCC 编译资源提取自 Weasel 0.17.4 官方安装包的 `data/opencc`；只使用数据，不安装、执行或复用其客户端、服务、注册代码和图标。OpenCC 采用 Apache-2.0。运行库包含的 glog、LevelDB、marisa-trie、yaml-cpp、Boost 与 predict 保留各自许可；原文在 `third_party/windows/licenses` 并复制到安装包。依赖锁中的 `windows_licenses` 记录许可文件的固定来源与摘要，不将许可来源标签误作二进制中未核验的依赖版本。

Windows TSF、候选窗、设置及安装器为本项目新增实现，采用 GPL-3.0-only。Windows 同样随包保留雾凇完整固定源码和词典/Lua 中的原始声明。7-Zip 26.03 仅用于构建时解包，保留官方缓存包并核验摘要，不随客户端分发。所有 Windows 下载的地址、版本、大小及 SHA-256 见 `dependencies.lock.json`；尚未进行 Windows Authenticode 代码签名，公开发布与实际宿主验收状态见验证记录。

Windows 首版模型独立锁定官方 LTS 资产 `558301149`（2026-09-12 更新），大小 `420343852` 字节，SHA-256 `9f80530f470033cfb6d4b44bb861b540f64100426f92dd0f87140883632a3d93`，仍为 amzxyz 的原始 CC-BY-4.0 模型。元数据位于 `windows_wanxiang_model`；下载与引擎使用均校验此摘要，未将同名资产替换视为可以跳过校验。macOS 的历史模型锁与已发布记录单独保留。
