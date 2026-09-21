# 同步时间与进度 Implementation Plan

**Goal:** Windows/macOS 同步页显示可验证的完成时间、当前阶段、已确认设备数量和停滞提示。

**Architecture:** Rust 在本机持久化双方签名回执确认的版本及观察时间，不改线上签名格式，不相信远端时钟。只有确认的新版本才更新时间，心跳和失败不更新时间。两端协调器报告实际导出、应用、确认与输入等待阶段；原生界面复用现有布局与主题。

**Tech Stack:** Rust/SQLite、WPF/C#、AppKit/Swift。

## 实施步骤

1. `sync/src/service.rs`：持久保存每设备双方确认时间；输出确认设备数、传输阶段与单调等待时长。没有对端时不能声称跨设备同步完成。
2. `windows/settings/Sync.cs`、`macos/Sources/DeviceSync.swift`：记录真实本机处理阶段及耗时，失败退避保持可见；不改变词库同步语义。
3. `windows/settings/SyncPage.cs`、`macos/Sources/DeviceSyncWindow.swift`、`DeviceSyncControls.swift`：时间独立于错误提示；进度用阶段和计数，不使用无依据的百分比；手动同步期间仍刷新。
4. `scripts/test_lan_sync.py`：测试确认才记时间、空轮询不更新、重启保留、退出清除。原生协调器和UI测试增加阶段、时间展示断言。
5. 执行 Rust tests、隔离 TLS 多节点、Windows 协调器与UI渲染；Mac由同一提交CI验证。更新 `docs/VALIDATION.md`，构建号9139，提交推送；相关CI通过再按现有授权发布0.4.4。

## 验收边界

- 最近成功时间指本机观察到双方已应用同一已知版本，不代表离线设备没有新修改。
- 未发生过确认显示“尚无成功记录”；升级后首次观察时间不伪造为历史时间。
- 等待超过30秒显示检查提示，不把长等待武断判为故障。
- 界面不显示词库内容、身份或控制令牌；时间/进度不写网络协议、不额外申请权限。
