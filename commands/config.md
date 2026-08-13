---
description: 配置中转商 base_url / 模型 / wire_api / 默认沙箱 / 超时
argument-hint: "[base_url=https://...] [model=gpt-5] [level=balanced|high] [wire_api=responses] [sandbox=read-only|workspace-write] [timeout=600]"
allowed-tools: Bash
---

用户请求配置 codex-offload，参数如下：

$ARGUMENTS

配置工具是 `"${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh"`，请按以下步骤处理：

1. **安全检查优先**：如果参数里出现疑似 API 密钥（如 sk- 开头的长字符串），**不要写入任何配置**，立刻停止并提醒用户——密钥贴进会话会留在对话记录里。让用户在另开的终端窗口执行：
   ```
   printf '%s' '<你的KEY>' > ~/.claude/codex-offload/token && chmod 600 ~/.claude/codex-offload/token
   ```
   （或运行 `"${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" set-token` 交互式输入，不回显。）
2. 对每个 `key=value` 形式的参数，运行 `ctl.sh set <key> <value>`。支持的 key：`base_url`、`model`、`level`（balanced=只分流 subagent 类子任务｜high=能分流的一律分流，含主线编码）、`wire_api`（默认 responses；新版 codex 已移除 chat 支持，中转商必须支持 Responses API）、`sandbox`（read-only|workspace-write）、`timeout`（秒）。如果用户只给了一个裸 URL（没写 key=），按 base_url 处理。
   注意：设置 `level` 后除了运行脚本，还要在本会话内**立即按新强度执行**（high=能分流的一律分流；balanced=只分流 subagent 类子任务）。
3. 如果没有给任何参数，运行 `ctl.sh status` 展示当前配置，并告诉用户本命令的用法。
4. 全部设置完后运行 `ctl.sh status` 把最终配置给用户，并建议运行 /codex-offload:test 验证连通性。
