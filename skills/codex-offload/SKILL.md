---
name: codex-offload
description: codex 分流决策规则——分流开启时，判断哪些子任务交给本地 codex 执行、任务描述怎么写、如何并行与复核。首次分流前先读本技能。
---

# codex 分流规则

前提：分流开关为 ON（SessionStart 已注入提示，或本会话执行过 /codex-offload:on）。开关 OFF 时 codex-run.sh 会直接拒绝执行，不要绕过。

## 调用方式

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh" [--cd <工作目录>] [--sandbox workspace-write] [--timeout <秒>] '<自包含任务描述>'
```

- stdout 即 codex 的最终结论；非 0 退出码表示失败，stderr 有日志尾部。
- 默认只读沙箱（read-only），写文件必须显式 `--sandbox workspace-write`。
- 预计超过 1 分钟的任务用后台 Bash（run_in_background）；多个独立任务并行发。

## 分流强度（config 里的 level）

- **balanced**（默认）：只分流 subagent 类子任务，主线编码与关键判断自己做（规则见下节）。
- **high**（激进）：只要任务能写成自包含描述、且 shell/文件级操作能完成，一律分流——包括主线编码、改文件、跑测试、写脚本。你的职责转为：拆解任务 → 写自包含任务描述 → 并行下发 → 复核 → 整合汇报。high 模式下写任务会大量出现，`git diff` 复核一步不可省略。

当前强度以 `ctl.sh status` 输出或 SessionStart 注入的内容为准。

## 什么任务分流（balanced 下需全部满足）

1. **自包含**：一段话能说清，不依赖本会话历史；
2. **只需要 shell / 文件级操作**：搜索、读代码、分析、审计、资料调研、独立机械修改、一次性脚本；
3. **结果错了代价可控**：有复核兜底，不是一锤定音的关键判断。

典型：原本会交给 Explore / general-purpose subagent 的任务。high 模式下条件 3 放宽为"复核可兜底"，条件 1、2 满足即分流。

## 什么任务不分流

- 需要继承本会话上下文的（fork 场景）；
- 需要 Claude Code 专属工具的：MCP、浏览器自动化、Artifact、记忆等；
- 结论直接决定后续方向的关键判断、最终把关；
- 用户明确点名要 Claude 亲自做的。

## 任务描述怎么写

- **自包含**：codex 完全看不到本会话，把必要背景压缩进描述；
- **指明范围**：用 `--cd` 定工作目录，描述里写清楚要看哪些路径/模块；
- **限定产出**：明确要求"返回精炼结论/清单，不要大段粘贴文件内容"——读回结果消耗的是 Claude token；
- **写任务列验收标准**：改了什么、怎么验证。

## 写任务与并行

- 写文件：`--sandbox workspace-write`，完成后必须 `git diff` 复核，复核通过才算数；向用户汇报时注明产出来自 codex。
- 多个写任务并行：用 `git worktree` 给每个任务开独立目录，各自 `--cd` 自己的 worktree，避免互相覆盖。

## 失败处理

- 单个任务失败最多重试 1 次（可微调任务描述后重发）；
- 连续失败就改回自己做或用普通 subagent，并把失败原因告知用户；
- 不要因为分流失败而静默丢弃子任务。
