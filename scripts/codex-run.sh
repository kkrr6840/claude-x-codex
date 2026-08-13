#!/usr/bin/env bash
# codex-offload 核心分发脚本:把一个自包含任务交给本地 codex CLI(第三方中转商)执行
# 用法: codex-run.sh [--cd <目录>] [--sandbox read-only|workspace-write] [--timeout <秒>] [--test] '<任务描述>'
# 成功: stdout 输出 codex 的最终结论; 失败: 非 0 退出码,stderr 输出日志尾部
set -euo pipefail

CFG_DIR="${CODEX_OFFLOAD_HOME:-$HOME/.claude/codex-offload}"
CFG_FILE="$CFG_DIR/config"
TOKEN_FILE="$CFG_DIR/token"

die() { echo "codex-run: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: codex-run.sh [选项] '<自包含任务描述>'
  --cd <目录>        codex 的工作目录(默认当前目录)
  --sandbox <模式>   read-only(默认) | workspace-write
  --timeout <秒>     超时(默认取配置,再默认 600)
  --test             连通性自检(发送最小任务,验证 base_url/token/wire_api)
EOF
  exit 0
}

ENABLED=0
BASE_URL=""
MODEL="gpt-5"
WIRE_API="responses"
SANDBOX_DEFAULT="read-only"
TIMEOUT_DEFAULT=600
# tr 去 \r 容忍 CRLF config;用 eval 而非 . <(...)(进程替换在受限环境会静默失败),与 ctl.sh 一致
if [ -f "$CFG_FILE" ]; then
  eval "$(tr -d '\r' < "$CFG_FILE")"
fi

WORKDIR="$PWD"
SANDBOX="$SANDBOX_DEFAULT"
TIMEOUT="$TIMEOUT_DEFAULT"
TEST=0
PROMPT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --cd)      WORKDIR="${2:?--cd 缺少目录}"; shift 2 ;;
    --sandbox) SANDBOX="${2:?--sandbox 缺少模式}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?--timeout 缺少秒数}"; shift 2 ;;
    --test)    TEST=1; shift ;;
    -h|--help) usage ;;
    --)        shift; PROMPT="$*"; break ;;
    -*)        die "未知参数: $1 (见 --help)" ;;
    *)         PROMPT="$*"; break ;;
  esac
done

# 硬开关: OFF 就是 OFF,任何会话都发不出去
[ "${ENABLED:-0}" = "1" ] || die "分流未开启。在 Claude Code 里执行 /codex-offload:on,或运行 ctl.sh enable"

command -v codex >/dev/null 2>&1 || die "未找到 codex CLI (brew install codex 或 npm i -g @openai/codex)"
[ -n "$BASE_URL" ] || die "未配置 base_url。执行 /codex-offload:config base_url=<中转商地址>"
[ -f "$TOKEN_FILE" ] || die "未配置 token。终端执行: printf '%s' '<KEY>' > $TOKEN_FILE && chmod 600 $TOKEN_FILE"

if [ "$TEST" = "1" ]; then
  PROMPT="Reply with exactly: ok"
  SANDBOX="read-only"
  TIMEOUT=120
fi

[ -n "$PROMPT" ] || die "缺少任务描述 (见 --help)"
case "$SANDBOX" in
  read-only|workspace-write) ;;
  *) die "sandbox 只能是 read-only 或 workspace-write" ;;
esac
case "$TIMEOUT" in
  ''|*[!0-9]*) die "timeout 必须是秒数(纯数字): $TIMEOUT" ;;
esac
[ -d "$WORKDIR" ] || die "工作目录不存在: $WORKDIR"

# 超时包装: 只认 GNU timeout(--version 能跑通)。
# 注意 Windows 自带的 System32 timeout.exe 是"等待N秒"命令,语义完全不同,必须排除
TIMEOUT_BIN=""
for cand in timeout gtimeout; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" --version >/dev/null 2>&1; then
    TIMEOUT_BIN="$cand"
    break
  fi
done

OUT="$(mktemp -t codex-offload-out.XXXXXX)"
LOG="$(mktemp -t codex-offload-log.XXXXXX)"
trap 'rm -f "$OUT"' EXIT

# token 去 \r\n(容忍 Windows 工具写出的 CRLF token 文件),空 token 提前拦截
RELAY_KEY="$(tr -d '\r\n' < "$TOKEN_FILE")"
[ -n "$RELAY_KEY" ] || die "token 文件为空: $TOKEN_FILE"

set +e
RELAY_API_KEY="$RELAY_KEY" \
${TIMEOUT_BIN:+"$TIMEOUT_BIN" "$TIMEOUT"} \
codex exec \
  -c 'model_providers.relay.name="relay"' \
  -c "model_providers.relay.base_url=\"$BASE_URL\"" \
  -c 'model_providers.relay.env_key="RELAY_API_KEY"' \
  -c "model_providers.relay.wire_api=\"$WIRE_API\"" \
  -c 'model_provider="relay"' \
  -m "$MODEL" \
  -s "$SANDBOX" \
  -C "$WORKDIR" \
  --skip-git-repo-check \
  --color never \
  -o "$OUT" \
  "$PROMPT" </dev/null >"$LOG" 2>&1
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
  if [ ! -s "$OUT" ]; then
    # 防御: codex 在管道/无 TTY 环境(尤其 Windows Git Bash)有静默退出无输出的已知问题(openai/codex#19945)
    echo "codex-run: codex 退出码 0 但没有产出结果。若在 Windows Git Bash 环境,这是 codex 的已知问题(openai/codex#19945),请改用 PowerShell 环境(codex-run.ps1)或 WSL" >&2
    echo "codex-run: 完整日志: $LOG" >&2
    exit 1
  fi
  cat "$OUT"
  echo
  rm -f "$LOG"
else
  if [ "$rc" -eq 124 ] && [ -n "$TIMEOUT_BIN" ]; then
    echo "codex-run: 超时(${TIMEOUT}s)被终止" >&2
  fi
  echo "codex-run: codex exec 失败 (exit $rc),日志尾部:" >&2
  tail -n 40 "$LOG" >&2
  echo "codex-run: 完整日志: $LOG" >&2
  exit "$rc"
fi
