---
description: 查看 codex 分流的开关状态与配置
allowed-tools: Bash
---

执行状态脚本（按本环境可用的工具二选一）：

- 有 Bash 工具：`"${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" status`
- 只有 PowerShell 工具（未装 Git Bash 的 Windows）：`& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" status`

把输出原样整理给用户看即可（不要执行其他动作）。如果发现 base_url 或 token 未配置，附带提示配置方法：/codex-offload:config 设置 base_url 等；token 需用户在终端自行写入文件（不要贴进会话）。
