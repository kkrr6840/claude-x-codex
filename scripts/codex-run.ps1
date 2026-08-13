# codex-run.ps1 -- codex-offload 核心分发脚本 (Windows PowerShell 5.1 版)
# 本脚本是 scripts/codex-run.sh 的孪生移植, 两者行为必须保持同步:
#   任何一边改了检查顺序 / 参数语义 / 提示文案, 另一边要跟着改。
# 用法: codex-run.ps1 [-Cd <目录>] [-Sandbox read-only|workspace-write] [-TimeoutSec <秒>] [-Test] '<任务描述>'
# 成功: stdout 输出 codex 的最终结论; 失败: 非 0 退出码, stderr 输出日志尾部
#
# 平台差异说明(相对 bash 版):
#   - 超时不依赖 GNU timeout, 用 Process.WaitForExit(毫秒) + taskkill /T /F 杀进程树, 恒定生效
#   - stdout/stderr 分别重定向到两个临时文件, 结束后把 stderr 追加到日志尾部(非严格交错)
#   - codex 若解析到 npm 的 .cmd 垫片, cmd.exe 会二次解析参数(% ^ & 等元字符有风险), 优先选 .exe
#   - token 只经文件读入环境变量 RELAY_API_KEY, 绝不进命令行参数, 脚本绝不打印其内容

[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Cd,
    [string]$Sandbox,
    [int]$TimeoutSec,
    [switch]$Test,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

# 显式设 EAP: 防止从 EAP=Stop 的会话点调时,原生命令的 stderr(如 taskkill)被包成终止错误
$ErrorActionPreference = 'Continue'

# 让重定向输出走无 BOM UTF-8(与 bash 侧管道约定一致); 无控制台时忽略失败
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
} catch { }

function Exit-CodexRunError {
    param([string]$Message)
    [Console]::Error.WriteLine('codex-run: ' + $Message)
    exit 1
}

function Show-Usage {
    $text = @'
用法: codex-run.ps1 [选项] '<自包含任务描述>'
  -Cd <目录>          codex 的工作目录(默认当前目录)
  -Sandbox <模式>     read-only(默认) | workspace-write
  -TimeoutSec <秒>    超时(默认取配置,再默认 600)
  -Test               连通性自检(发送最小任务,验证 base_url/token/wire_api)
'@
    Write-Output $text
    exit 0
}

# 读取 KEY=value 纯文本配置(与 bash 版共用同一文件; 值若被单/双引号包裹则去掉包裹)
function Read-ConfigFile {
    param([string]$Path)
    $result = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
    $lines = [System.IO.File]::ReadAllLines($Path)
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '') { continue }
        if ($trimmed.StartsWith('#')) { continue }
        $eq = $trimmed.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $trimmed.Substring(0, $eq).Trim()
        $val = $trimmed.Substring($eq + 1).Trim()
        if ($val.Length -ge 2) {
            $first = $val.Substring(0, 1)
            $last = $val.Substring($val.Length - 1, 1)
            if (($first -eq "'" -and $last -eq "'") -or ($first -eq '"' -and $last -eq '"')) {
                $val = $val.Substring(1, $val.Length - 2)
            }
        }
        $result[$key] = $val
    }
    return $result
}

# Windows 命令行参数标准转义(MSVCRT 规则): 含空白/引号才加引号, 引号前反斜杠翻倍再 \" 转义
function Format-CommandLineArg {
    param([string]$Value)
    if ($null -eq $Value) { $Value = '' }
    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

if ($Help) { Show-Usage }

# ---- 配置定位: CODEX_OFFLOAD_HOME 优先, 否则 $HOME/.claude/codex-offload ----
if ($env:CODEX_OFFLOAD_HOME) {
    $CfgDir = $env:CODEX_OFFLOAD_HOME
} else {
    $CfgDir = Join-Path $env:USERPROFILE '.claude\codex-offload'
}
$CfgFile = Join-Path $CfgDir 'config'
$TokenFile = Join-Path $CfgDir 'token'

# ---- 默认值 + 配置覆盖(与 bash 版一致) ----
$ENABLED = '0'
$BASE_URL = ''
$MODEL = 'gpt-5'
$WIRE_API = 'responses'
$SANDBOX_DEFAULT = 'read-only'
$TIMEOUT_DEFAULT = 600

$cfg = Read-ConfigFile -Path $CfgFile
if ($cfg.ContainsKey('ENABLED')) { $ENABLED = $cfg['ENABLED'] }
if ($cfg.ContainsKey('BASE_URL')) { $BASE_URL = $cfg['BASE_URL'] }
if ($cfg.ContainsKey('MODEL')) { $MODEL = $cfg['MODEL'] }
if ($cfg.ContainsKey('WIRE_API')) { $WIRE_API = $cfg['WIRE_API'] }
if ($cfg.ContainsKey('SANDBOX_DEFAULT')) { $SANDBOX_DEFAULT = $cfg['SANDBOX_DEFAULT'] }
if ($cfg.ContainsKey('TIMEOUT_DEFAULT')) {
    $parsed = 0
    if ([int]::TryParse($cfg['TIMEOUT_DEFAULT'], [ref]$parsed)) { $TIMEOUT_DEFAULT = $parsed }
}

# ---- 参数归位(未显式给的取默认) ----
if ($PSBoundParameters.ContainsKey('Cd')) {
    $Workdir = $Cd
} else {
    $Workdir = (Get-Location).Path
}
if ($PSBoundParameters.ContainsKey('Sandbox')) {
    $SandboxMode = $Sandbox
} else {
    $SandboxMode = $SANDBOX_DEFAULT
}
if ($PSBoundParameters.ContainsKey('TimeoutSec')) {
    $Timeout = $TimeoutSec
} else {
    $Timeout = $TIMEOUT_DEFAULT
}

# 位置参数拼任务描述; 首个 '--' 之后全当描述, 未知 -xxx 参数报错(与 bash 版一致)
$Prompt = ''
if ($RemainingArgs -and $RemainingArgs.Count -gt 0) {
    $parts = @($RemainingArgs)
    if ($parts[0] -eq '--') {
        if ($parts.Count -gt 1) {
            $parts = $parts[1..($parts.Count - 1)]
        } else {
            $parts = @()
        }
    } elseif ($parts[0] -match '^-') {
        # 注意: 裸 -- 会被 PowerShell 绑定器消费掉,到不了这里;要传以 - 开头的任务描述,
        # 需用带引号的 '--' 作为首个位置参数(能穿透绑定器,由上面的 -eq '--' 分支接住)
        Exit-CodexRunError ('未知参数: ' + $parts[0] + " (见 -Help;若这是任务描述本身,请在它前面加一个带引号的 '--' 参数)")
    }
    $Prompt = ($parts -join ' ')
}

# ---- 硬开关: OFF 就是 OFF, 任何会话都发不出去 ----
if ($ENABLED -ne '1') {
    Exit-CodexRunError '分流未开启。在 Claude Code 里执行 /codex-offload:on,或运行 ctl.ps1 enable'
}

# ---- codex CLI 存在性检查(优先 .exe, 避免 .cmd 垫片被 cmd.exe 二次解析) ----
$codexCandidates = @(Get-Command -Name 'codex' -CommandType Application -All -ErrorAction SilentlyContinue)
$CodexPath = ''
foreach ($cand in $codexCandidates) {
    if ($cand.Path -match '\.exe$') { $CodexPath = $cand.Path; break }
}
if ($CodexPath -eq '' -and $codexCandidates.Count -gt 0) {
    $CodexPath = $codexCandidates[0].Path
}
if ($CodexPath -eq '') {
    Exit-CodexRunError '未找到 codex CLI (npm i -g @openai/codex)'
}

if ($BASE_URL -eq '') {
    Exit-CodexRunError '未配置 base_url。执行 /codex-offload:config base_url=<中转商地址>'
}
if (-not (Test-Path -LiteralPath $TokenFile -PathType Leaf)) {
    Exit-CodexRunError ('未配置 token。终端执行: [IO.File]::WriteAllText("' + $TokenFile + '", ''<KEY>'')')
}

# ---- --test 语义: 固定最小任务 + read-only + 120 秒(覆盖用户显式给的值, 与 bash 版一致) ----
if ($Test) {
    $Prompt = 'Reply with exactly: ok'
    $SandboxMode = 'read-only'
    $Timeout = 120
}

if ($Prompt -eq '') {
    Exit-CodexRunError '缺少任务描述 (见 -Help)'
}
if ($SandboxMode -ne 'read-only' -and $SandboxMode -ne 'workspace-write') {
    Exit-CodexRunError 'sandbox 只能是 read-only 或 workspace-write'
}
if (-not (Test-Path -LiteralPath $Workdir -PathType Container)) {
    Exit-CodexRunError ('工作目录不存在: ' + $Workdir)
}

# ---- 临时文件: 结果文件 / 日志(stdout) / 日志(stderr) / 空 stdin ----
$OutFile = [System.IO.Path]::GetTempFileName()
$LogFile = [System.IO.Path]::GetTempFileName()
$ErrFile = [System.IO.Path]::GetTempFileName()
$StdinFile = [System.IO.Path]::GetTempFileName()

$rc = 1
$timedOut = $false
$succeeded = $false

try {
    # 密钥纪律: token 只进环境变量(codex 通过 env_key=RELAY_API_KEY 读取), 不进命令行
    $token = ([System.IO.File]::ReadAllText($TokenFile)).TrimEnd("`r", "`n")
    if ($token.Length -eq 0) {
        # PS 5.1 对 $env:X 赋空串等于删除变量,codex 会报"变量未设置"这类费解错误,提前拦截
        Exit-CodexRunError ('token 文件为空: ' + $TokenFile)
    }
    $env:RELAY_API_KEY = $token
    $token = $null

    $codexArgs = @(
        'exec',
        '-c', 'model_providers.relay.name="relay"',
        '-c', ('model_providers.relay.base_url="{0}"' -f $BASE_URL),
        '-c', 'model_providers.relay.env_key="RELAY_API_KEY"',
        '-c', ('model_providers.relay.wire_api="{0}"' -f $WIRE_API),
        '-c', 'model_provider="relay"',
        '-m', $MODEL,
        '-s', $SandboxMode,
        '-C', $Workdir,
        '--skip-git-repo-check',
        '--color', 'never',
        '-o', $OutFile,
        $Prompt
    )
    $quoted = @()
    foreach ($a in $codexArgs) { $quoted += Format-CommandLineArg -Value $a }
    $argString = $quoted -join ' '

    $proc = $null
    try {
        # -ErrorAction Stop 必须给: PS 5.1 中 Start-Process 启动失败是非终止错误,不加则 catch 捕不到
        $proc = Start-Process -FilePath $CodexPath -ArgumentList $argString `
            -NoNewWindow -PassThru -ErrorAction Stop `
            -RedirectStandardInput $StdinFile `
            -RedirectStandardOutput $LogFile `
            -RedirectStandardError $ErrFile
    } catch {
        Exit-CodexRunError ('无法启动 codex: ' + $_.Exception.Message)
    }
    # PS 5.1 已知坑: 先摸一次 Handle, 否则进程退出后 ExitCode 可能取不到
    $null = $proc.Handle

    $timeoutMs = [long]$Timeout * 1000
    if ($timeoutMs -le 0 -or $timeoutMs -gt [int]::MaxValue) {
        # 0 表示不限时(对齐 GNU timeout 的 "duration 0 disables timeout")
        $proc.WaitForExit()
        $finished = $true
    } else {
        $finished = $proc.WaitForExit([int]$timeoutMs)
    }

    if (-not $finished) {
        # 超时: 杀整棵进程树(codex 可能有子进程), 对齐 GNU timeout 的 124
        $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
        $null = & $taskkill /PID $proc.Id /T /F 2>&1
        try { $null = $proc.WaitForExit(5000) } catch { }
        $rc = 124
        $timedOut = $true
    } else {
        try { $proc.WaitForExit() } catch { }   # 确保重定向内容全部落盘
        $rc = $proc.ExitCode
        if ($null -eq $rc) { $rc = 1 }
    }

    # 合并日志: stderr 追加到 stdout 日志之后(bash 版是 2>&1 交错, 此处为顺序拼接)
    try {
        $errText = [System.IO.File]::ReadAllText($ErrFile)
        if ($errText.Length -gt 0) {
            [System.IO.File]::AppendAllText($LogFile, $errText, (New-Object System.Text.UTF8Encoding($false)))
        }
    } catch { }

    $emptyResult = $false
    if ($rc -eq 0) {
        $outText = [System.IO.File]::ReadAllText($OutFile)
        if ($outText.Trim().Length -eq 0) {
            # 防御: codex 有"静默退出无产出"的已知问题(openai/codex#19945),不能当成功上报
            $rc = 1
            $emptyResult = $true
        } else {
            Write-Output $outText
            $succeeded = $true
        }
    }
    if (-not $succeeded) {
        if ($timedOut) {
            [Console]::Error.WriteLine(('codex-run: 超时({0}s)被终止' -f $Timeout))
        }
        if ($emptyResult) {
            [Console]::Error.WriteLine('codex-run: codex 退出码 0 但没有产出结果(openai/codex#19945 一类的静默失败),日志尾部:')
        } else {
            [Console]::Error.WriteLine(('codex-run: codex exec 失败 (exit {0}),日志尾部:' -f $rc))
        }
        try {
            $logLines = [System.IO.File]::ReadAllLines($LogFile)
            $start = $logLines.Length - 40
            if ($start -lt 0) { $start = 0 }
            for ($i = $start; $i -lt $logLines.Length; $i++) {
                [Console]::Error.WriteLine($logLines[$i])
            }
        } catch { }
        [Console]::Error.WriteLine('codex-run: 完整日志: ' + $LogFile)
    }
} finally {
    Remove-Item -LiteralPath Env:\RELAY_API_KEY -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $StdinFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ErrFile -Force -ErrorAction SilentlyContinue
    if ($succeeded) {
        Remove-Item -LiteralPath $LogFile -Force -ErrorAction SilentlyContinue
    }
}

exit $rc
