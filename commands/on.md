---
description: 开启 codex 分流（当前会话立即生效，新会话自动生效）
allowed-tools: Bash
---

第一步，执行开关脚本（按本环境可用的工具二选一）：

- 有 Bash 工具（macOS / Linux / 装了 Git Bash 的 Windows）：`"${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" enable`
- 只有 PowerShell 工具（未装 Git Bash 的 Windows）：`& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" enable`

第二步，从现在起在本会话中启用 codex 分流。分流入口对应为 `bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh" '<自包含任务描述>'`（Bash 环境）或 `& "${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.ps1" '<自包含任务描述>'`（PowerShell 环境），按脚本输出里显示的**分流强度**执行：

- **balanced**（默认）：自包含、不依赖本会话上下文的子任务（跨文件搜索、代码分析审计、资料调研、独立机械修改、一次性脚本、第二意见审查）优先分流给 codex，替代 Explore/general-purpose subagent；主线编码与关键判断仍由你完成。
- **high**（激进）：只要任务能写成自包含描述、且 shell/文件级操作能完成（含主线编码/改文件/跑测试），一律分流给 codex；你负责拆解任务、写任务描述、并行下发、复核与整合。

首次分流前先读本插件的 codex-offload skill 获取完整规则。

最后向用户简短确认分流已开启（如果 base_url 或 token 未配置，提醒用户运行 /codex-offload:config 和 /codex-offload:test），不要执行其他动作。
