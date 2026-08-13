---
description: 配置中转商 base_url / 模型 / wire_api / 默认沙箱 / 超时
argument-hint: "[base_url=https://...] [model=gpt-5] [level=balanced|high] [wire_api=responses] [sandbox=read-only|workspace-write] [timeout=600]"
allowed-tools: Bash
---

用户请求配置 codex-offload，参数如下：

$ARGUMENTS

配置工具是 `"${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh"`。

**安全红线（两种模式通用）**：密钥绝不通过命令参数或会话消息写入配置。如果参数或用户消息里出现疑似 API 密钥（如 sk- 开头的长字符串），不要用它写任何文件，提醒用户：密钥已留在会话记录里，建议之后到中转商后台作废换新；正确做法是在**另开的终端窗口**执行：
```
printf '%s' '<你的KEY>' > ~/.claude/codex-offload/token && chmod 600 ~/.claude/codex-offload/token
```

## 模式一：带参数（快速设置）

对每个 `key=value` 形式的参数，运行 `ctl.sh set <key> <value>`。支持的 key：`base_url`、`model`、`level`（balanced=只分流 subagent 类子任务｜high=能分流的一律分流，含主线编码）、`wire_api`（默认 responses；新版 codex 已移除 chat 支持，中转商必须支持 Responses API）、`sandbox`（read-only|workspace-write）、`timeout`（秒）。如果用户只给了一个裸 URL（没写 key=），按 base_url 处理。设置 `level` 后要在本会话内立即按新强度执行。全部设置完运行 `ctl.sh status` 展示结果，建议用户跑 /codex-offload:test。

## 模式二：不带参数（引导式配置）

$ARGUMENTS 为空时，逐步引导用户完成配置（顺序有讲究：先配好 base_url 和 token，才能拉取真实模型列表供选择）：

1. 先运行 `ctl.sh status` 展示当前配置，已配好的项告诉用户可以直接沿用。
2. **base_url**：问用户中转商的接口地址（自由输入；提醒一般以 `/v1` 结尾，且中转商必须支持 Responses API 即 `/v1/responses` 端点）。拿到后 `ctl.sh set base_url <url>`。
3. **token**：用 `test -f ~/.claude/codex-offload/token && echo 已配置 || echo 未配置` 检查（**绝不 cat 该文件内容**）。未配置就把安全红线里的 printf 命令给用户，让其在另开的终端执行，等用户回复完成后再检查一次确认。
4. **model（从真实列表里选，不让用户盲填）**：运行 `ctl.sh models` 拉取中转商实际支持的模型列表。
   - 成功：优先筛选适合编码任务的模型（gpt-5 系 / codex 系 / o 系），用 AskUserQuestion 给出最多 4 个推荐选项让用户选（用户也可通过 Other 自填）；如果列表很长，同时把完整列表（或按前缀归组的摘要）展示出来供参考。选定后 `ctl.sh set model <id>`。
   - 失败（如中转商不支持 /models）：告知原因，回退为自由输入。
5. **level**：用 AskUserQuestion 二选一——balanced（默认：只分流搜索/分析/调研类子任务，质量优先）或 high（激进：能分流的一律分流含主线编码，省 token 优先）。
6. wire_api / sandbox / timeout 是高级项，不主动问，用户提到才设。
7. 收尾：运行 `ctl.sh status` 展示最终配置；问用户是否现在开启分流（是则运行 `ctl.sh enable`）并建议跑 /codex-offload:test 验证连通性。
