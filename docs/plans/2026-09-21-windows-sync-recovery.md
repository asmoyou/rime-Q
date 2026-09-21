# Windows 同步恢复 Implementation Plan

**Goal:** 解决正常引擎学习记录导致整批同步拒绝的问题，保留所有本机数据，并定位快打放行英文的条件。

**Architecture:** 保持 v1 全拼协议与旧版 macOS 兼容；Windows 适配层将同步记录与暂不支持的本机编码分开，写回时合并本机保留记录。协议校验表直接嵌入自共享资源。失败重试退避，手动同步可立即重试。

**Tech Stack:** C#/.NET Framework、Rust 同步服务、C++ librime/TSF、Python 隔离测试。

## 步骤

1. 使用已安装同步组件、临时数据和合成编码复现 `invalid syllable`；只读查询现用服务，不输出词条或令牌。
2. 修改 `windows/settings/Sync.cs`，分离同步子集与完整引擎快照，覆盖 capture、acknowledge、apply 和 recover；失败退避 30 秒，明确显示保留数量。
3. 在 `scripts/build_windows.py` 嵌入 `sync/resources/pinyin.txt`，不引入另一份手工维护的校验表。
4. 增加 `windows/tests/sync_coordinator_tests.cs` 和 `scripts/test_windows_sync_coordinator.py`：真实隔离服务、合成引擎快照；验证混合编码、远端添加/删除、恢复、退避、手动重试、本机保留记录，禁止访问生产管道。
5. 检查输入路径与同步导出耗时；仅基于可重复证据调整实现，不把 TSF 模拟验收称为 ChatGPT 宿主验收。
6. 运行相关检查并更新 `docs/VALIDATION.md`。安装、CI、发布分别报告事实，不把源码修改称为本机已修复。
