# claude-x-codex (codex-offload)

Claude Code 插件：把自包含子任务分流给本地 **codex CLI**（走第三方中转商的 base_url + API key）执行，节省 Claude token。

原理：subagent 类任务本来就是"干净上下文、只回结论"，换成 codex 跑，Claude 只花"发任务 + 读结论"的少量 token，子任务的探索、读文件、试错全部走中转商额度。探查型重度会话可省 30%–50% 的 Claude token。

## 前置条件

- 已安装 [codex CLI](https://github.com/openai/codex)：`brew install codex` 或 `npm i -g @openai/codex`
- 一个 OpenAI 兼容中转商的 base_url 和 API key
- macOS / Linux（脚本为 bash，Windows 未适配）

## 安装

```
# Claude Code 会话内：
/plugin marketplace add kkrr6840/claude-x-codex
/plugin install codex-offload@claude-x-codex
```

或本地开发方式加载：

```
git clone https://github.com/kkrr6840/claude-x-codex
claude --plugin-dir ./claude-x-codex
```

## 配置（三步）

```
# 1. 设 base_url 和模型（会话内）
/codex-offload:config base_url=https://你的中转商/v1 model=gpt-5

# 2. 写入 token —— 在另开的终端窗口执行（不要把 key 贴进 Claude 会话！）
printf '%s' '<你的KEY>' > ~/.claude/codex-offload/token && chmod 600 ~/.claude/codex-offload/token

# 3. 开启并自检
/codex-offload:on
/codex-offload:test
```

注意：**新版 codex CLI（≥0.4x）只支持 Responses API**（`wire_api=responses`，已是默认值），中转商必须支持 `/v1/responses` 端点——只提供 Chat Completions 的中转商用不了（除非降级 codex 版本）。`:test` 失败时会按错误类型给排查建议。

## 命令一览

| 命令 | 作用 |
|---|---|
| `/codex-offload:on` | 开启分流（当前会话立即生效，新会话经 SessionStart hook 自动生效） |
| `/codex-offload:off` | 关闭分流（三层保险：hook 不注入、会话内声明停用、脚本拒绝执行） |
| `/codex-offload:status` | 查看开关、配置、codex 版本 |
| `/codex-offload:config` | 设置 base_url / model / wire_api / sandbox / timeout |
| `/codex-offload:test` | 连通性自检 |
| `/codex-offload:codex <任务>` | 手动把一个任务分流给 codex |

开启后无需手动触发：Claude 会按 skill 里的规则，把适合的子任务（跨文件搜索、分析审计、资料调研、独立修改、一次性脚本等）自动分流给 codex，并复核其产出。

## 分流强度

```
/codex-offload:config level=high    # 切激进模式
/codex-offload:config level=balanced # 切回默认
```

| 强度 | 行为 | 适合 |
|---|---|---|
| `balanced`（默认） | 只分流 subagent 类子任务（搜索/分析/调研/独立修改），主线编码和关键判断 Claude 自己做 | 日常使用，质量优先 |
| `high`（激进） | 只要任务能自包含描述、shell/文件操作能完成，**一律分流**（含主线编码/改文件/跑测试）；Claude 只做拆解、下发、复核、整合 | 额度紧张时，省 token 优先 |

high 模式省得更多，但依赖复核兜底——codex 的每次文件改动 Claude 都会 `git diff` 复核后才采信。

## 工作机制

开关通过三层配合真正生效：

1. **SessionStart hook**（`scripts/session-start.sh`）：仅当开关为 ON 时向新会话注入分流指引；
2. **`:on` / `:off` 命令正文**：让当前会话立即改变行为（hook 只在会话启动时跑一次）；
3. **`scripts/codex-run.sh` 硬检查**：开关 OFF 时直接拒绝执行——关了就是关了。

## 安全设计

- codex 执行的命令**不经过 Claude Code 的权限系统**，只靠 codex 自己的沙箱。因此默认 `read-only`，写文件需逐任务显式 `--sandbox workspace-write`，且产出必须复核。
- token 存 `~/.claude/codex-offload/token`（0600），只通过环境变量传给 codex，不上命令行参数（`ps` 不可见）、不进会话记录。
- **不修改** 你的 `~/.codex/config.toml`——中转商配置全部通过 `codex exec -c` 每次调用时临时覆盖。
- 代码内容会发给第三方中转商，敏感项目请先 `/codex-offload:off`。

## 配置文件

- `~/.claude/codex-offload/config` — 开关与配置（shell 格式）
- `~/.claude/codex-offload/token` — API key（0600）

卸载：`/plugin uninstall codex-offload`，配置目录可手动删除 `rm -rf ~/.claude/codex-offload`。

## License

MIT
