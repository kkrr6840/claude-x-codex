#!/usr/bin/env bash
# SessionStart hook: 分流开关为 ON 时向会话注入分流指引,OFF 时什么都不输出
set -u

CFG_DIR="${CODEX_OFFLOAD_HOME:-$HOME/.claude/codex-offload}"
ENABLED=0
LEVEL="balanced"
# shellcheck disable=SC1090
[ -f "$CFG_DIR/config" ] && . "$CFG_DIR/config"

[ "${ENABLED:-0}" = "1" ] || exit 0

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
RUN="$ROOT/scripts/codex-run.sh"

if [ "${LEVEL:-balanced}" = "high" ]; then
  policy="分流强度: high(激进)。只要任务能写成自包含描述、且用 shell/文件级操作能完成(读代码/搜索/分析/写代码/改文件/跑测试/写脚本/资料调研),就一律分流给 codex 执行——包括主线编码任务,不限于 subagent 类子任务。你的职责转为: 拆解任务、写自包含任务描述、并行下发、复核与整合产出。仅以下情况自己做: 上下文无法压缩进任务描述、需要 MCP/浏览器/Artifact 等专属工具、用户点名要你亲自做、以及对 codex 产出的复核与最终把关。"
else
  policy="分流强度: balanced(默认)。自包含、不依赖本会话上下文的子任务(跨文件搜索/代码分析审计/资料调研/独立机械修改/一次性脚本/第二意见审查),优先分流给 codex,替代 Explore/general-purpose subagent;主线编码与关键判断仍由你完成。"
fi

ctx="codex-offload 分流已开启。$policy
用法: bash \"$RUN\" [--cd <工作目录>] [--sandbox workspace-write] [--timeout <秒>] '<自包含任务描述>' —— stdout 即 codex 的最终结论,长任务用后台 Bash,多个独立任务并行发。
规则: 1) 任务描述必须自包含,codex 看不到本会话; 2) 要求 codex 返回精炼结论,不要大段文件转储; 3) 默认只读沙箱,确需写文件才加 --sandbox workspace-write,完成后必须复核改动; 4) 并行写文件用 git worktree 隔离; 5) 需要会话上下文、需要 MCP/浏览器等专属工具、或属于关键决策的任务不分流。
首次分流前先读 codex-offload 插件的 skill 获取完整规则。用户用 /codex-offload:off 关闭后立即停止分流。"

python3 - "$ctx" <<'PY'
import json, sys
ctx = sys.argv[1]
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": ctx,
    }
}, ensure_ascii=False))
PY
