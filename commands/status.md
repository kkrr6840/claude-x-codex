---
description: 查看 codex 分流的开关状态与配置
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" status`

上面是当前状态。把它原样整理给用户看即可（不要执行其他动作）。如果发现 base_url 或 token 未配置，附带提示配置方法：/codex-offload:config 设置 base_url 等；token 需用户在终端自行写入文件（不要贴进会话）。
