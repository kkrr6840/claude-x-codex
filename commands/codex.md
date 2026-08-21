---
description: 手动把一个任务分流给 codex 执行
argument-hint: "<自包含任务描述>"
allowed-tools: Bash, PowerShell
---

用户要求把以下任务分流给 codex 执行：

$ARGUMENTS

执行方式：`bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh" --cd <合适的工作目录> '<任务描述>'`；本环境只有 PowerShell 工具（未装 Git Bash 的 Windows）时用 `& "${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.ps1" -Cd <目录> '<任务描述>'`。要点：

1. 任务描述必须**自包含**——codex 看不到本会话，必要时把背景信息补写进描述里；同时要求 codex 返回精炼结论，不要大段粘贴文件内容。
2. 默认只读沙箱。只有任务明确需要修改文件时才加 `--sandbox workspace-write`，完成后用 `git diff` 复核改动，复核通过再向用户汇报。
3. 预计耗时较长的任务用后台 Bash（run_in_background）运行；多个独立任务并行发。
4. 把 codex 的结论整理后交给用户，并注明这是 codex 的产出。
5. 如果脚本报"分流未开启"，提示用户先运行 /codex-offload:on。
