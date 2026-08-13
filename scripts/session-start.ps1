# session-start.ps1 -- session-start.sh 的孪生脚本(目标 Windows PowerShell 5.1,不依赖 pwsh 7 语法)。
# 两者需保持行为同步: 任一侧修改注入文案/逻辑时,必须同步修改另一侧。
# SessionStart hook 的 PowerShell 入口,仅在"无 Git Bash 的 Windows"上真正干活:
# 检测到 bash 可用时直接 exit 0,由 bash 版 hook 条目负责注入,避免双重注入。
# 分流开关为 ON 时向会话注入分流指引,OFF 时什么都不输出。

# 有可用的 Git Bash 就退位,交给 session-start.sh 注入。
# 两个坑都要防:
# 1) System32 下的 WSL bash.exe 不算数——hooks 的 bash 条目交给它时无法解析 Windows
#    路径,若因它误退位则两侧都不注入(静默失效);
# 2) 必须用 -All 枚举全部候选——WSL 与 Git Bash 并存时 System32 常排 PATH 前面,
#    只看第一个会漏掉后面的 Git Bash,导致 bash 条目与本脚本双重注入
$bashCmds = @(Get-Command bash -All -ErrorAction SilentlyContinue)
foreach ($bc in $bashCmds) {
    $bashSrc = [string]$bc.Source
    if ([string]::IsNullOrEmpty($bashSrc)) { $bashSrc = [string]$bc.Path }
    $isWslBash = ($env:windir -and $bashSrc -like (Join-Path $env:windir '*'))
    if (-not $isWslBash) {
        # 存在任何非 WSL 的 bash(如 Git Bash) → 退位
        exit 0
    }
}

# 配置目录: 优先 CODEX_OFFLOAD_HOME,否则 %USERPROFILE%\.claude\codex-offload(与 bash 版共用同一配置;回退链与 ctl.ps1 一致)
if ($env:CODEX_OFFLOAD_HOME) {
    $cfgDir = $env:CODEX_OFFLOAD_HOME
} elseif ($env:USERPROFILE) {
    $cfgDir = Join-Path $env:USERPROFILE '.claude\codex-offload'
} else {
    $cfgDir = Join-Path $HOME '.claude/codex-offload'
}

$ENABLED = '0'
$LEVEL = 'balanced'

# 读 config(每行 KEY=value 的纯文本,值可能被引号包裹,读取时剥掉包裹引号)
$cfgFile = Join-Path $cfgDir 'config'
if (Test-Path -LiteralPath $cfgFile -PathType Leaf) {
    foreach ($line in [System.IO.File]::ReadAllLines($cfgFile)) {
        $t = $line.Trim()
        if ($t -eq '') { continue }
        if ($t.StartsWith('#')) { continue }
        $idx = $t.IndexOf('=')
        if ($idx -lt 1) { continue }
        $key = $t.Substring(0, $idx).Trim()
        $val = $t.Substring($idx + 1).Trim()
        # 剥掉 bash printf %q 可能产生的包裹引号: $'val' / 'val' / "val"(与 ctl.ps1 逻辑一致)
        if ($val.StartsWith("`$'") -and $val.EndsWith("'") -and $val.Length -ge 3) {
            $val = $val.Substring(2, $val.Length - 3)
        } elseif ($val.Length -ge 2) {
            $first = $val.Substring(0, 1)
            $last = $val.Substring($val.Length - 1, 1)
            if (($first -eq "'" -and $last -eq "'") -or ($first -eq '"' -and $last -eq '"')) {
                $val = $val.Substring(1, $val.Length - 2)
            }
        }
        if ($key -ceq 'ENABLED') { $ENABLED = $val }
        if ($key -ceq 'LEVEL') { $LEVEL = $val }
    }
}

# 硬开关: 不为 1 时静默退出(与 bash 版一致)
if ($ENABLED -cne '1') {
    exit 0
}
if ($LEVEL -eq '') {
    $LEVEL = 'balanced'
}

# 插件根: 优先 CLAUDE_PLUGIN_ROOT,否则脚本自身上级目录
if ($env:CLAUDE_PLUGIN_ROOT) {
    $root = $env:CLAUDE_PLUGIN_ROOT
} else {
    $root = Split-Path -Parent $PSScriptRoot
}
$run = Join-Path $root 'scripts\codex-run.ps1'

# policy 文案与 bash 版逐字一致
if ($LEVEL -ceq 'high') {
    $policy = '分流强度: high(激进)。只要任务能写成自包含描述、且用 shell/文件级操作能完成(读代码/搜索/分析/写代码/改文件/跑测试/写脚本/资料调研),就一律分流给 codex 执行——包括主线编码任务,不限于 subagent 类子任务。你的职责转为: 拆解任务、写自包含任务描述、并行下发、复核与整合产出。仅以下情况自己做: 上下文无法压缩进任务描述、需要 MCP/浏览器/Artifact 等专属工具、用户点名要你亲自做、以及对 codex 产出的复核与最终把关。'
} else {
    $policy = '分流强度: balanced(默认)。自包含、不依赖本会话上下文的子任务(跨文件搜索/代码分析审计/资料调研/独立机械修改/一次性脚本/第二意见审查),优先分流给 codex,替代 Explore/general-purpose subagent;主线编码与关键判断仍由你完成。'
}

# 注入文案与 bash 版结构一致;"用法"一行改为 PowerShell 形式,并注明无 Git Bash 环境
$usage = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$run`" [-Cd <工作目录>] [-Sandbox workspace-write] [-TimeoutSec <秒>] '<自包含任务描述>'"
$lines = @(
    ("codex-offload 分流已开启。" + $policy),
    ("用法: " + $usage + " —— stdout 即 codex 的最终结论,长任务用后台方式运行,多个独立任务并行发。当前是无 Git Bash 的 Windows 环境,请用 PowerShell 工具调用上述命令。"),
    "规则: 1) 任务描述必须自包含,codex 看不到本会话; 2) 要求 codex 返回精炼结论,不要大段文件转储; 3) 默认只读沙箱,确需写文件才加 -Sandbox workspace-write,完成后必须复核改动; 4) 并行写文件用 git worktree 隔离; 5) 需要会话上下文、需要 MCP/浏览器等专属工具、或属于关键决策的任务不分流。",
    "首次分流前先读 codex-offload 插件的 skill 获取完整规则。用户用 /codex-offload:off 关闭后立即停止分流。"
)
$ctx = $lines -join "`n"

# 单行 JSON 输出到 stdout(PS 5.1 会把非 ASCII 转成 \uXXXX,仍是合法 JSON,且规避控制台编码问题)
$payload = [ordered]@{
    hookSpecificOutput = [ordered]@{
        hookEventName     = 'SessionStart'
        additionalContext = $ctx
    }
}
Write-Output (ConvertTo-Json -InputObject $payload -Compress -Depth 5)
exit 0
