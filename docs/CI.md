# CI 运行范围

工作流为 `.github/workflows/ci.yml`，任务选择由 `scripts/ci_plan.py` 计算。

| 触发场景 | 运行内容 |
| --- | --- |
| 分支提交，尚无 PR | 不自动运行；可手动全量验证 |
| 面向 main 的 PR，仅修改 README、AGENTS 或 docs | Linux 上的路由回归与客户端功能契约检查 |
| PR 修改 macOS 客户端或专用构建脚本 | 轻量检查、Mac 通用包及实际安装验收 |
| PR 修改 Windows 客户端或专用构建脚本 | 轻量检查、双架构注册、打包及实际安装验收 |
| PR 修改 C++ 核心 | 轻量检查、三平台核心测试 |
| PR 修改共享同步服务 | 轻量检查、三平台同步、Docker 隔离网络、两端打包安装 |
| PR 修改共享词库、依赖锁、许可、CI 或未分类路径 | 全量验证 |
| main 推送含代码变更，或手动 workflow_dispatch | 全量验证 |
| main 推送仅含上述仓库文档 | 轻量检查 |

多个范围的改动取并集。随包离线帮助和第三方许可属于构建输入，不按仓库文档跳过。

PR 用 merge base 到 PR head 的完整 Git 差异；main 用推送前后提交的差异，包含一次推送中的全部提交。禁用重命名识别，移动文件仍检查原平台的删除。差异无法确定时运行全量，不使用有文件数量截断的事件文件清单。

只有 main 的 push 自动触发，因此开发分支不会再同时运行 push 和 pull_request 两套工作流。新 PR 提交取消同一个 PR 的过时运行；不主动中断正在执行的 main 或手动验收。工作流保留轻量检查，纯文档改动也会产生实际检查结果。

Mac 打包已经编译通用客户端，核心任务不再重复 `swift build`。各任务有超时上限。已经压缩的 PKG/EXE 上传时不再 ZIP 压缩；PR 附件保留 3 天，main/手动安装包保留 7 天，同步进程和沙箱报告保留 3 天。这只改变后续上传，已有附件仍按原期限过期。

发布仍须使用目标 main 提交通过全量验收的同一次运行产物；仅有 PR 的局部检查不能作为发布依据。若目标提交只有文档改动，应在该 main 提交手动运行全量验收后再交付版本。

本地验证：

```sh
python3 scripts/test_ci_plan.py
python3 scripts/test_client_parity.py
go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.7 -shellcheck= .github/workflows/ci.yml
```

2026-09-14 核对时，仓库为公开仓库，使用标准 GitHub 托管 runner。GitHub 仓库事件 API 记录的 PublicEvent 为 2026-09-10 07:05:14 UTC（北京时间 15:05:14）。3,000 分钟是 Pro/Team 面向私有仓库的月度额度；公开后的标准 runner 运行不消耗该额度。[GitHub 计费说明](https://docs.github.com/en/actions/concepts/billing-and-usage)规定这类运行免收执行分钟费用。runner 占用时间与 CPU 时间、账单金额不同；账户实际收费来源需要核对账单明细，不能仅凭这里的运行次数判断。上述调整减少无关运行和附件保留，但不宣称已经降低实际账单。
