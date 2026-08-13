---
description: 开启 codex 分流（当前会话立即生效，新会话自动生效）
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" enable`

上面是开关脚本的执行结果。从现在起，在本会话中启用 codex 分流，分流入口是 `bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh" '<自包含任务描述>'`，按输出里显示的**分流强度**执行：

- **balanced**（默认）：自包含、不依赖本会话上下文的子任务（跨文件搜索、代码分析审计、资料调研、独立机械修改、一次性脚本、第二意见审查）优先分流给 codex，替代 Explore/general-purpose subagent；主线编码与关键判断仍由你完成。
- **high**（激进）：只要任务能写成自包含描述、且 shell/文件级操作能完成（含主线编码/改文件/跑测试），一律分流给 codex；你负责拆解任务、写任务描述、并行下发、复核与整合。

首次分流前先读本插件的 codex-offload skill 获取完整规则。

现在只需向用户简短确认分流已开启（如果 base_url 或 token 未配置，提醒用户运行 /codex-offload:config 和 /codex-offload:test），不要执行其他动作。
