#!/usr/bin/env bash
# codex-offload 配置管理工具
# 用法: ctl.sh {enable|disable|status|set <key> <val>|set-token}
set -euo pipefail

CFG_DIR="${CODEX_OFFLOAD_HOME:-$HOME/.claude/codex-offload}"
CFG_FILE="$CFG_DIR/config"
TOKEN_FILE="$CFG_DIR/token"

# 默认值（config 文件覆盖）
ENABLED=0
BASE_URL=""
MODEL="gpt-5"
WIRE_API="responses"
SANDBOX_DEFAULT="read-only"
TIMEOUT_DEFAULT=600
LEVEL="balanced"

load() {
  # tr 去 \r: 容忍被 Windows 编辑器改成 CRLF 的 config(否则值尾带 \r 静默出错)。
  # 用 eval 而不是 . <(...): 进程替换依赖 /dev/fd,在部分受限环境(沙箱/精简 Git Bash)会静默失败
  if [ -f "$CFG_FILE" ]; then
    eval "$(tr -d '\r' < "$CFG_FILE")"
  fi
}

save() {
  mkdir -p "$CFG_DIR"
  chmod 700 "$CFG_DIR"
  # 写不带引号的纯 KEY=value(值已由 set 校验为无特殊字符):
  # 保证 PowerShell 孪生脚本能按字面读取,不要改回 printf %q(它的反斜杠转义 PS 不认)
  {
    printf 'ENABLED=%s\n' "$ENABLED"
    printf 'BASE_URL=%s\n' "$BASE_URL"
    printf 'MODEL=%s\n' "$MODEL"
    printf 'WIRE_API=%s\n' "$WIRE_API"
    printf 'SANDBOX_DEFAULT=%s\n' "$SANDBOX_DEFAULT"
    printf 'TIMEOUT_DEFAULT=%s\n' "$TIMEOUT_DEFAULT"
    printf 'LEVEL=%s\n' "$LEVEL"
  } > "$CFG_FILE"
  chmod 600 "$CFG_FILE"
}

cmd="${1:-status}"
shift || true
load

case "$cmd" in
  enable)
    ENABLED=1; save
    echo "codex-offload: 已开启 (ON),分流强度: $LEVEL"
    ;;
  disable)
    ENABLED=0; save
    echo "codex-offload: 已关闭 (OFF)"
    ;;
  set)
    key="${1:?用法: ctl.sh set <base_url|model|wire_api|sandbox|timeout|level> <值>}"
    val="${2:?缺少值}"
    # 值禁止空白/引号/shell 元字符(与 ctl.ps1 的 Save-Config 黑名单一致):
    # config 会被 bash source(纯 KEY=value 不带引号),也要能被 PowerShell 按字面读取
    case "$val" in
      *[[:space:]\'\"\`\$\;\&\|\<\>\(\)\\]*)
        echo "值不能包含空格/引号等特殊 shell 字符: $val" >&2; exit 1 ;;
    esac
    case "$key" in
      base_url) BASE_URL="$val" ;;
      model)    MODEL="$val" ;;
      wire_api)
        case "$val" in
          responses) WIRE_API="$val" ;;
          chat)
            WIRE_API="$val"
            echo "警告: 新版 codex CLI(≥0.4x)已移除 chat 支持,只认 Responses API,此设置大概率会失败;仅在你固定使用旧版 codex 时有效" >&2 ;;
          *) echo "wire_api 只能是 responses 或 chat(chat 仅限旧版 codex)" >&2; exit 1 ;;
        esac ;;
      sandbox)
        case "$val" in
          read-only|workspace-write) SANDBOX_DEFAULT="$val" ;;
          *) echo "sandbox 只能是 read-only 或 workspace-write" >&2; exit 1 ;;
        esac ;;
      timeout)
        case "$val" in
          ''|*[!0-9]*) echo "timeout 必须是秒数(纯数字)" >&2; exit 1 ;;
          *) TIMEOUT_DEFAULT="$val" ;;
        esac ;;
      level)
        case "$val" in
          balanced|high) LEVEL="$val" ;;
          *) echo "level 只能是 balanced(默认,只分流 subagent 类子任务) 或 high(激进,能分流的一律分流)" >&2; exit 1 ;;
        esac ;;
      token|key|api_key|apikey)
        echo "禁止用 set 传密钥(会留在会话记录里)。请用: ctl.sh set-token (从 stdin 读入)" >&2
        exit 1 ;;
      *)
        echo "未知配置项: $key (支持 base_url|model|wire_api|sandbox|timeout|level)" >&2
        exit 1 ;;
    esac
    save
    echo "已设置 $key"
    ;;
  set-token)
    mkdir -p "$CFG_DIR"
    chmod 700 "$CFG_DIR"
    if [ -t 0 ]; then
      printf '请输入 API token(输入不回显): ' >&2
      IFS= read -rs tok
      echo >&2
    else
      IFS= read -r tok || true
    fi
    if [ -z "${tok:-}" ]; then
      echo "token 为空,未保存" >&2
      exit 1
    fi
    umask 077
    printf '%s' "$tok" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    echo "token 已保存到 $TOKEN_FILE (权限 0600)"
    ;;
  models)
    [ -n "$BASE_URL" ] || { echo "先配置 base_url (ctl.sh set base_url <url>)" >&2; exit 1; }
    [ -f "$TOKEN_FILE" ] || { echo "先配置 token ($TOKEN_FILE)" >&2; exit 1; }
    command -v curl >/dev/null 2>&1 || { echo "需要 curl (macOS/Linux/Windows10+ 均自带)" >&2; exit 1; }
    # token 通过 stdin 的 curl 配置传入,不上命令行参数
    if ! resp="$(printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '\r\n' < "$TOKEN_FILE")" \
        | curl -sS --max-time 20 -K - -w '\n%{http_code}' "${BASE_URL%/}/models" 2>&1)"; then
      echo "获取模型列表失败: $resp" >&2
      exit 1
    fi
    code="${resp##*$'\n'}"
    body="${resp%$'\n'*}"
    case "$code" in
      2[0-9][0-9]) ;;
      *) echo "获取模型列表失败: HTTP $code" >&2; exit 1 ;;
    esac
    ids=""
    # 优先 python3 精确解析;没有 python3(如 Git Bash)则用 grep/sed 粗解析回退
    if command -v python3 >/dev/null 2>&1; then
      ids="$(printf '%s' "$body" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
items = data.get("data") if isinstance(data, dict) else data
if not isinstance(items, list):
    items = []
ids = sorted({m.get("id") for m in items if isinstance(m, dict) and m.get("id")})
print("\n".join(ids))' 2>/dev/null)" || ids=""
    fi
    if [ -z "$ids" ]; then
      ids="$(printf '%s' "$body" \
        | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | sed -E 's/^"id"[[:space:]]*:[[:space:]]*"(.*)"$/\1/' \
        | sort -u)"
    fi
    [ -n "$ids" ] || { echo "接口没有返回模型列表(中转商可能不支持 /models 端点)" >&2; exit 1; }
    printf '%s\n' "$ids"
    ;;
  status)
    if [ "${ENABLED:-0}" = "1" ]; then sw="ON"; else sw="OFF"; fi
    echo "开关:     $sw"
    echo "强度:     $LEVEL $([ "$LEVEL" = "high" ] && echo '(激进:能分流的一律分流)' || echo '(默认:只分流 subagent 类子任务)')"
    echo "base_url: ${BASE_URL:-<未配置>}"
    echo "model:    $MODEL"
    echo "wire_api: $WIRE_API"
    echo "sandbox:  $SANDBOX_DEFAULT (默认)"
    echo "timeout:  ${TIMEOUT_DEFAULT}s (默认)"
    if [ -f "$TOKEN_FILE" ]; then
      echo "token:    已配置 ($TOKEN_FILE)"
    else
      echo "token:    未配置 (printf '%s' '<KEY>' > $TOKEN_FILE && chmod 600 $TOKEN_FILE)"
    fi
    if command -v codex >/dev/null 2>&1; then
      echo "codex:    $(codex --version 2>/dev/null)"
    else
      echo "codex:    未安装 (brew install codex 或 npm i -g @openai/codex)"
    fi
    ;;
  *)
    echo "用法: ctl.sh {enable|disable|status|set <key> <val>|set-token|models}" >&2
    exit 1
    ;;
esac
