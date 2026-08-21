---
description: 关闭 codex 分流（当前会话与新会话都停止分流）
allowed-tools: Bash, PowerShell
---

第一步，执行开关脚本（按本环境可用的工具二选一）：

- 有 Bash 工具：`"${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" disable`
- 只有 PowerShell 工具（未装 Git Bash 的 Windows）：`& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" disable`

第二步，从现在起在本会话中**停止一切 codex 分流**，恢复使用普通 subagent（Explore/general-purpose 等）处理子任务。脚本层也会拒绝执行（codex-run 检测到 OFF 会直接报错），不要尝试绕过。

最后向用户简短确认分流已关闭，不要执行其他动作。
