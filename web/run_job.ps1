<#
.SYNOPSIS
    Web 服务专用任务执行器：按顺序跑一串现有脚本，输出全部走 stdout（UTF-8）。
.DESCRIPTION
    真实业务逻辑一律仍在 sync / run_all / audit / maint / dedupe 里，本脚本只是「编排壳」，
    不含任何下载/判重/体检规则。这样 Web 化不改引擎，引擎也不依赖 Web。

    为什么参数走 Base64：PowerShell 5.1 的命令行解析会吃掉裸双引号，JSON 串直接当参数传进来
    会被拆坏（中文与空格路径更是重灾区，见 PROJECT.md 坑 9）。所以 web/server.mjs 传
    -ChainB64 = base64(utf8(JSON))，这里再解码，全程不过命令行引号层。

    链格式（数组，元素顺序执行）：
      [{ "script": "sync.ps1", "params": { "Run": true, "Quiet": true } },
       { "script": "tools\\maint.ps1", "params": { "Action": "NetCheck" } }]
    params 里布尔 true => 开关；布尔 false / null => 省略；其它值转字符串交给目标脚本强转。
    调用目标脚本必须用哈希表 splatting（PROJECT.md 坑 14：数组 splatting 会按位置错位）。
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\web\run_job.ps1 -ChainB64 <base64>
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ChainB64
)

$ErrorActionPreference = 'Continue'
$ProjectRoot = Split-Path -Parent $PSScriptRoot

# 输出被重定向到 Node 的管道时，[Console]::OutputEncoding 决定对方读到的字节。
# 这里先用无 BOM 的 UTF-8；子脚本若把它换回带 BOM 的 UTF8，Node 侧 TextDecoder 会自动吞掉 BOM。
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Utf8NoBom
[Console]::InputEncoding   = $Utf8NoBom

function Write-Banner([string]$text) {
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host ("  " + $text) -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
}

$chain = $null
try {
    $json = $Utf8NoBom.GetString([System.Convert]::FromBase64String($ChainB64))
    $chain = ConvertFrom-Json -InputObject $json
} catch {
    Write-Banner '任务链配置解析失败'
    Write-Host ("  " + $_.Exception.Message) -ForegroundColor Red
    exit 91
}

$steps = @($chain)
if ($steps.Count -eq 0) {
    Write-Host '[web] 任务链为空，无事可做' -ForegroundColor Yellow
    exit 92
}

$rootFull = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\') + '\'
$fail = 0
$i = 0

foreach ($step in $steps) {
    $i++
    $rel = [string]$step.script
    $cand = if ([System.IO.Path]::IsPathRooted($rel)) { $rel } else { Join-Path $ProjectRoot $rel }

    $full = ''
    try { $full = [System.IO.Path]::GetFullPath($cand) } catch { $full = $cand }

    # 只允许执行本项目目录内的 .ps1：避免这个壳被用来跑任意程序
    if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host ("[web] 拒绝执行项目外的脚本: {0}" -f $rel) -ForegroundColor Red
        $fail++; continue
    }
    if ([System.IO.Path]::GetExtension($full) -ne '.ps1') {
        Write-Host ("[web] 只允许 .ps1: {0}" -f $rel) -ForegroundColor Red
        $fail++; continue
    }
    if (-not [System.IO.File]::Exists($full)) {
        Write-Host ("[web] 脚本不存在: {0}" -f $full) -ForegroundColor Red
        $fail++; continue
    }

    $h = @{}
    $shown = @()
    foreach ($p in @($step.params.PSObject.Properties)) {
        if (-not $p.Name) { continue }
        if ($p.Name -notmatch '^[A-Za-z][A-Za-z0-9]*$') {
            Write-Host ("[web] 忽略非法参数名: {0}" -f $p.Name) -ForegroundColor Yellow
            continue
        }
        $v = $p.Value
        if ($v -is [bool]) {
            if ($v) { $h[$p.Name] = $true; $shown += ('-' + $p.Name) }
        } elseif ($null -ne $v) {
            $h[$p.Name] = [string]$v
            $shown += ('-{0} {1}' -f $p.Name, $v)
        }
    }

    $label = [System.IO.Path]::GetFileName($full)
    if ($shown.Count -gt 0) { $label += ' ' + ($shown -join ' ') }

    Write-Banner ("步骤 {0}/{1}   {2}" -f $i, $steps.Count, $label)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $full @h
    } catch {
        Write-Host ("[web] 该步骤抛出终止性错误: {0}" -f $_.Exception.Message) -ForegroundColor Red
        $fail++
    }
    $sw.Stop()
    Write-Host ("[web] 步骤结束，用时 {0:N1}s" -f $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray
}

Write-Banner ("任务链完成   共 {0} 步，失败 {1} 步" -f $steps.Count, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
