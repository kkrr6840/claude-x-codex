---
description: 用最小任务验证中转商连通性（base_url / token / wire_api / model）
allowed-tools: Bash
---

运行连通性自检：`bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh" --test`（Bash 工具的 timeout 参数给到 180000 毫秒，自检可能需要 1-2 分钟）。

- **成功**（stdout 含 ok）：告诉用户配置可用，可以开始分流。
- **失败**：把 stderr 里的关键错误行给用户看，并按常见原因给排查建议：
  1. `401` / `403` / `unauthorized` → token 不对或额度不足，检查 token 文件内容；
  2. `404` / `not found` → base_url 路径不对，试试补上或去掉末尾的 `/v1`（用 /codex-offload:config 改）；
  3. 报 `wire_api = "chat" is no longer supported` → 新版 codex 只支持 Responses API，运行 `ctl.sh set wire_api responses` 后重测；若报 `/responses` 路径 404/400 → 中转商不支持 Responses API，告知用户需换支持 `/v1/responses` 的中转商，或降级 codex 版本；
  4. 模型名相关错误 → `ctl.sh set model <中转商支持的模型名>`；
  5. `分流未开启` → 先运行 /codex-offload:on。
- 失败时**最多按建议调整重试 2 次**，仍失败就把完整信息交还用户判断，不要继续盲试。
