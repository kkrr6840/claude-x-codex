# ctl.ps1 — codex-offload 配置管理工具 (Windows PowerShell 5.1 版)
#
# 本脚本是 scripts/ctl.sh 的孪生移植版,两者行为必须保持同步:
# 任何一边修改子命令/校验规则/输出文案,另一边必须同步修改。
# 用法: ctl.ps1 {enable|disable|status|set <key> <val>|set-token|models}
#
# 平台差异说明:
# - 本 .ps1 文件本身必须保存为「带 BOM 的 UTF-8」,否则 PowerShell 5.1 会按
#   ANSI 代码页读源码,中文字符串全部乱码。不要"修复"掉这个 BOM。
# - 脚本在运行时写出的文件(config/token)则必须是「无 BOM 的 UTF-8 + LF 换行」,
#   因为它们会被 bash 侧 source/读取,BOM 或 CRLF 都会毒死 bash。
# - bash 版写 config 用 printf %q(值可能带单引号包裹);本版读取时会剥掉包裹
#   引号,写入时统一写成不带引号的 KEY=value,并拒绝含空格/引号等特殊字符的值。
# - 权限收紧: bash 版用 chmod 600/700;本版对 token 文件用 icacls 移除继承、
#   只保留当前用户,失败不致命。
# - 密钥纪律: token 永远不出现在进程命令行参数里,脚本绝不打印 token 内容。

$ErrorActionPreference = 'Stop'

# 让重定向 stdout/stderr 时输出 UTF-8(失败不致命,如无控制台句柄时)
try {
  [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
} catch { }

function Write-Err {
  param([string]$Msg)
  [Console]::Error.WriteLine($Msg)
}

# ---------- 路径(与 bash 版一致: CODEX_OFFLOAD_HOME 优先) ----------
if ($env:CODEX_OFFLOAD_HOME) {
  $CfgDir = $env:CODEX_OFFLOAD_HOME
} elseif ($env:USERPROFILE) {
  $CfgDir = Join-Path $env:USERPROFILE '.claude\codex-offload'
} else {
  $CfgDir = Join-Path $HOME '.claude/codex-offload'
}
$CfgFile = Join-Path $CfgDir 'config'
$TokenFile = Join-Path $CfgDir 'token'

# ---------- 默认值(config 文件覆盖),键集与 bash 版一致 ----------
$cfg = @{
  ENABLED         = '0'
  BASE_URL        = ''
  MODEL           = 'gpt-5'
  WIRE_API        = 'responses'
  SANDBOX_DEFAULT = 'read-only'
  TIMEOUT_DEFAULT = '600'
  LEVEL           = 'balanced'
}
$CfgKeys = @('ENABLED', 'BASE_URL', 'MODEL', 'WIRE_API', 'SANDBOX_DEFAULT', 'TIMEOUT_DEFAULT', 'LEVEL')

function Load-Config {
  if (-not (Test-Path -LiteralPath $CfgFile)) { return }
  # -Encoding UTF8 必须显式给: PS 5.1 对无 BOM 文件默认按 ANSI 代码页解码,非 ASCII 值会乱码
  foreach ($line in @(Get-Content -LiteralPath $CfgFile -Encoding UTF8)) {
    if ($line -cmatch '^([A-Z_]+)=(.*)$') {
      $k = $Matches[1]
      $v = $Matches[2].Trim()
      # 剥掉 bash printf %q 可能产生的包裹引号: 'val' / "val" / $'val'
      if ($v.StartsWith("`$'") -and $v.EndsWith("'") -and $v.Length -ge 3) {
        $v = $v.Substring(2, $v.Length - 3)
      } elseif ($v.Length -ge 2 -and
                (($v.StartsWith("'") -and $v.EndsWith("'")) -or
                 ($v.StartsWith('"') -and $v.EndsWith('"')))) {
        $v = $v.Substring(1, $v.Length - 2)
      }
      if ($cfg.ContainsKey($k)) { $cfg[$k] = $v }
    }
  }
}

function Save-Config {
  if (-not (Test-Path -LiteralPath $CfgDir)) {
    New-Item -ItemType Directory -Path $CfgDir -Force | Out-Null
  }
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($k in $CfgKeys) {
    $v = [string]$cfg[$k]
    # config 会被 bash 侧 source: 不带引号的 KEY=value,值里出现空格/引号或
    # 其他 shell 特殊字符都会破坏解析甚至造成注入,一律拒绝写入
    if ($v -match '[\s''"`$;&|<>()\\]') {
      Write-Err "配置值不允许包含空格/引号等特殊字符,拒绝写入: $k"
      exit 1
    }
    $lines.Add("$k=$v")
  }
  # 无 BOM UTF-8 + LF 换行(CRLF 会让 bash 读到值尾带 \r)
  $text = ($lines -join "`n") + "`n"
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($CfgFile, $text, $utf8NoBom)
}

# ---------- 子命令分发(与 bash 版 case 一致,大小写敏感) ----------
$cmd = 'status'
if ($args.Count -ge 1 -and -not [string]::IsNullOrEmpty([string]$args[0])) {
  $cmd = [string]$args[0]
}
Load-Config

switch -CaseSensitive ($cmd) {

  'enable' {
    $cfg['ENABLED'] = '1'
    Save-Config
    Write-Output ("codex-offload: 已开启 (ON),分流强度: " + $cfg['LEVEL'])
    exit 0
  }

  'disable' {
    $cfg['ENABLED'] = '0'
    Save-Config
    Write-Output "codex-offload: 已关闭 (OFF)"
    exit 0
  }

  'set' {
    # bash 的 ${1:?} / ${2:?} 对「缺参」和「空串」都报错,这里保持一致
    $key = ''
    $val = ''
    if ($args.Count -ge 2) { $key = [string]$args[1] }
    if ($args.Count -ge 3) { $val = [string]$args[2] }
    if ([string]::IsNullOrEmpty($key)) {
      Write-Err '用法: ctl.ps1 set <base_url|model|wire_api|sandbox|timeout|level> <值>'
      exit 1
    }
    if ([string]::IsNullOrEmpty($val)) {
      Write-Err '缺少值'
      exit 1
    }
    switch -CaseSensitive ($key) {
      'base_url' { $cfg['BASE_URL'] = $val }
      'model' { $cfg['MODEL'] = $val }
      'wire_api' {
        if ($val -ceq 'responses') {
          $cfg['WIRE_API'] = $val
        } elseif ($val -ceq 'chat') {
          $cfg['WIRE_API'] = $val
          Write-Err '警告: 新版 codex CLI(≥0.4x)已移除 chat 支持,只认 Responses API,此设置大概率会失败;仅在你固定使用旧版 codex 时有效'
        } else {
          Write-Err 'wire_api 只能是 responses 或 chat(chat 仅限旧版 codex)'
          exit 1
        }
      }
      'sandbox' {
        if ($val -ceq 'read-only' -or $val -ceq 'workspace-write') {
          $cfg['SANDBOX_DEFAULT'] = $val
        } else {
          Write-Err 'sandbox 只能是 read-only 或 workspace-write'
          exit 1
        }
      }
      'timeout' {
        if ($val -match '^[0-9]+$') {
          $cfg['TIMEOUT_DEFAULT'] = $val
        } else {
          Write-Err 'timeout 必须是秒数(纯数字)'
          exit 1
        }
      }
      'level' {
        if ($val -ceq 'balanced' -or $val -ceq 'high') {
          $cfg['LEVEL'] = $val
        } else {
          Write-Err 'level 只能是 balanced(默认,只分流 subagent 类子任务) 或 high(激进,能分流的一律分流)'
          exit 1
        }
      }
      { @('token', 'key', 'api_key', 'apikey') -ccontains $_ } {
        Write-Err '禁止用 set 传密钥(会留在会话记录里)。请用: ctl.ps1 set-token (从 stdin 读入)'
        exit 1
      }
      default {
        Write-Err "未知配置项: $key (支持 base_url|model|wire_api|sandbox|timeout|level)"
        exit 1
      }
    }
    Save-Config
    Write-Output "已设置 $key"
    exit 0
  }

  'set-token' {
    if (-not (Test-Path -LiteralPath $CfgDir)) {
      New-Item -ItemType Directory -Path $CfgDir -Force | Out-Null
    }
    $tok = $null
    if (-not [Console]::IsInputRedirected) {
      # 终端交互: 不回显读入,再转回明文写文件(BSTR 用完立即清零)
      # 注意: PS 5.1 的 Read-Host 有约 1022 字符输入上限,超长 token 建议改用管道方式
      $sec = Read-Host -Prompt '请输入 API token(输入不回显;超长 token 请改用管道: echo <token> | ctl.ps1 set-token)' -AsSecureString
      $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
      try {
        $tok = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
      } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
      }
    } else {
      # stdin 管道输入: 读第一行(与 bash 版 read -r 一致)
      $tok = [Console]::In.ReadLine()
    }
    if ($null -ne $tok) { $tok = $tok.Trim() }
    if ([string]::IsNullOrEmpty($tok)) {
      Write-Err 'token 为空,未保存'
      exit 1
    }
    # 无 BOM UTF-8,且不带尾部换行(与 bash 版 printf '%s' 一致)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($TokenFile, $tok, $utf8NoBom)
    # 尽力收紧权限: 移除继承,只留当前用户(等价 chmod 600),失败不致命
    $aclOk = $false
    if (Get-Command icacls -ErrorAction SilentlyContinue) {
      $oldEap = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      try {
        & icacls $TokenFile /inheritance:r /grant:r ('{0}:F' -f $env:USERNAME) 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $aclOk = $true }
      } catch { }
      $ErrorActionPreference = $oldEap
    }
    if ($aclOk) {
      Write-Output "token 已保存到 $TokenFile (已收紧 NTFS 权限,仅当前用户可访问)"
    } else {
      Write-Output "token 已保存到 $TokenFile (注意: NTFS 权限收紧失败,请手动检查该文件权限)"
    }
    exit 0
  }

  'models' {
    if ([string]::IsNullOrEmpty($cfg['BASE_URL'])) {
      Write-Err '先配置 base_url (ctl.ps1 set base_url <url>)'
      exit 1
    }
    if (-not (Test-Path -LiteralPath $TokenFile)) {
      Write-Err "先配置 token ($TokenFile)"
      exit 1
    }
    $token = ([System.IO.File]::ReadAllText($TokenFile)).Trim()
    $base = ([string]$cfg['BASE_URL']).TrimEnd('/')
    # PS5.1 默认可能不带 TLS1.2,先补上
    try {
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    $resp = $null
    try {
      # token 只进请求头,不进命令行参数
      $resp = Invoke-WebRequest -Uri ($base + '/models') `
        -Headers @{ Authorization = ('Bearer ' + $token) } `
        -TimeoutSec 20 -UseBasicParsing -ErrorAction Stop
    } catch [System.Net.WebException] {
      $r = $_.Exception.Response
      if ($null -ne $r) {
        $code = [int]$r.StatusCode
        $desc = ''
        try { $desc = [string]$r.StatusDescription } catch { }
        Write-Err ("获取模型列表失败: HTTP $code $desc").TrimEnd()
      } else {
        Write-Err ('获取模型列表失败: ' + $_.Exception.Message)
      }
      exit 1
    } catch {
      Write-Err ('获取模型列表失败: ' + $_.Exception.Message)
      exit 1
    }
    $json = $null
    try {
      $json = $resp.Content | ConvertFrom-Json
    } catch {
      Write-Err '获取模型列表失败: 响应不是有效 JSON'
      exit 1
    }
    # 与 bash 版 python 逻辑一致: dict 取 data 字段,否则按数组处理
    $items = @()
    if ($json -is [System.Array]) {
      $items = $json
    } elseif ($null -ne $json -and $null -ne $json.PSObject.Properties['data']) {
      $items = @($json.data)
    }
    $idList = New-Object System.Collections.Generic.List[string]
    foreach ($m in $items) {
      if ($null -eq $m) { continue }
      $p = $m.PSObject.Properties['id']
      if ($null -ne $p -and -not [string]::IsNullOrEmpty([string]$p.Value)) {
        $idList.Add([string]$p.Value)
      }
    }
    if ($idList.Count -eq 0) {
      Write-Err '接口没有返回模型列表(中转商可能不支持 /models 端点)'
      exit 1
    }
    # 序数排序 + 去重,贴近 bash 版 python sorted(set(...))
    $ids = $idList.ToArray()
    [Array]::Sort($ids, [System.StringComparer]::Ordinal)
    $prev = $null
    foreach ($id in $ids) {
      if ($id -cne $prev) { Write-Output $id }
      $prev = $id
    }
    exit 0
  }

  'status' {
    if ($cfg['ENABLED'] -eq '1') { $sw = 'ON' } else { $sw = 'OFF' }
    Write-Output "开关:     $sw"
    if ($cfg['LEVEL'] -ceq 'high') {
      $lvlDesc = '(激进:能分流的一律分流)'
    } else {
      $lvlDesc = '(默认:只分流 subagent 类子任务)'
    }
    Write-Output ('强度:     ' + $cfg['LEVEL'] + ' ' + $lvlDesc)
    if ([string]::IsNullOrEmpty($cfg['BASE_URL'])) {
      Write-Output 'base_url: <未配置>'
    } else {
      Write-Output ('base_url: ' + $cfg['BASE_URL'])
    }
    Write-Output ('model:    ' + $cfg['MODEL'])
    Write-Output ('wire_api: ' + $cfg['WIRE_API'])
    Write-Output ('sandbox:  ' + $cfg['SANDBOX_DEFAULT'] + ' (默认)')
    Write-Output ('timeout:  ' + $cfg['TIMEOUT_DEFAULT'] + 's (默认)')
    if (Test-Path -LiteralPath $TokenFile) {
      Write-Output "token:    已配置 ($TokenFile)"
    } else {
      Write-Output 'token:    未配置 (运行 ctl.ps1 set-token 写入)'
    }
    if (Get-Command codex -ErrorAction SilentlyContinue) {
      $ver = ''
      $oldEap = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      try {
        $ver = [string](& codex --version 2>$null | Select-Object -First 1)
      } catch { }
      $ErrorActionPreference = $oldEap
      Write-Output "codex:    $ver"
    } else {
      Write-Output 'codex:    未安装 (npm i -g @openai/codex)'
    }
    exit 0
  }

  default {
    Write-Err '用法: ctl.ps1 {enable|disable|status|set <key> <val>|set-token|models}'
    exit 1
  }
}
