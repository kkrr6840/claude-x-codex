---
description: 关闭 codex 分流（当前会话与新会话都停止分流）
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" disable`

上面是开关脚本的执行结果。从现在起，在本会话中**停止一切 codex 分流**，恢复使用普通 subagent（Explore/general-purpose 等）处理子任务。脚本层也会拒绝执行（codex-run.sh 检测到 OFF 会直接报错），不要尝试绕过。

现在只需向用户简短确认分流已关闭，不要执行其他动作。
