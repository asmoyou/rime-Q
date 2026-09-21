# 完整学习记录同步 Implementation Plan

**Goal:** Windows 与 macOS 均同步合法的引擎学习编码，不再把非全拼学习记录留在本机。

**Architecture:** 区分手动词条编辑的全拼校验与引擎快照的结构校验。协议 v2 接收 ASCII 字母编码及原大小写，保留现有词条键、同步组、签名历史、删除关系和权重；继续接受历史 v1 操作并按旧规则验证。网络握手 v2 拒绝旧版交互并给出升级提示，存储版本升级防止旧组件误开新数据，不要求重新配对。

**Tech Stack:** Rust 同步核心、C#/C++ Windows 客户端、Swift macOS 客户端、Python 真实服务与引擎测试。

## 验收步骤

1. `sync/tests/native_codes.rs`：英文、简码、混合大小写及长编码，恶意控制字符/超限仍拒绝；保留旧签名操作和存储升级。先验证旧实现失败，再运行 `cargo test --locked --manifest-path sync/Cargo.toml`。
2. `sync/src/model.rs`、`store.rs`、`service.rs`：协议/存储 v2，保留历史键空间和 v1 操作；同版本完整传输，旧版本在传词库前拒绝并显示升级提示。
3. `windows/settings/Sync.cs`：移除共享子集与本机保留分支；完整 capture/apply/ack/recover；保留 30 秒退避和手动重试。`macos/Sources/DeviceSync.swift` 改用引擎结构校验并增加相同退避。
4. 两端保留手动新增/导入的全拼校验；同步只放开音节语义，不能放开行注入、容量、权重和授权限制。
5. 真实 Windows 协调器、Swift 协调器、六设备 TLS/原生引擎场景加入相同非全拼样本，验证添加、更新权重、删除、重启和中断恢复。Mac 验证由 macOS CI 执行，不能在 Windows 声称已跑 Mac 真机。
6. 真实旧版辅助程序与新版混用测试：升级提示、无非法词条传输；同组逐端升级后恢复完整同步，不丢旧记录或生成重复词条。
7. 统一 0.4.4 与递增 Windows 构建号，推送并检查相关 CI，按仓库交付约定发布对应产物；不把旧的 9137 临时方案发布为最终修复。
