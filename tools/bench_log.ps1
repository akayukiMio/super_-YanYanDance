<#
.SYNOPSIS
    日志链路压测：固定行数模拟 run_all 的输出量，量出「谁在拖慢日志」。
.DESCRIPTION
    背景：有人反应浏览器控制台跑同样的任务比命令行慢。要判断是不是 Web 层的开销，就得把
    “PS 写日志” 和 “服务转发日志” 分开量。本脚本只做一件事：按 run_all 的日志形态（常驻
    StreamWriter 缓冲 + 每行一次彩色 Write-Host）刷固定行数，然后报自己的耗时。

    用法：
      1) 命令行基线      powershell -File tools\bench_log.ps1 -N 40000 -Mark CLI
      2) 经由 Web 服务   设 GALLERY_WEB_BENCH=1 起服务，POST /api/jobs {"key":"bench"}
      3) 打开页面挂上 SSE 再跑一次，对比 logs\_benchresult.txt 里的 lines_per_sec

    判读：经由 Web 的行速如果 **不低于** 命令行基线，就说明瓶颈不在服务转发，
    而在别处（并发实例触发源站冷却、前端渲染卡顿、任务参数不同等）。
#>
param(
    [int]$N = 40000,
    [string]$Mark = 'CLI'
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8

$log = Join-Path $ProjectRoot "logs\_bench_$Mark.media.log"
$w = New-Object System.IO.StreamWriter($log, $false, $utf8)
$w.AutoFlush = $false

$fmt = '   [img {0,4}/{1}] OK    0001.jpg   {2,5} KB  [26-08]某画廊搬运测试项目'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
for ($i = 1; $i -le $N; $i++) {
    $line = ($fmt -f $i, $N, ($i % 900))
    $w.WriteLine($line)
    if (($i % 200) -eq 0) { $w.Flush() }
    Write-Host $line -ForegroundColor Green
}
$w.Flush(); $w.Dispose()
$sw.Stop()

$r = ("MARK={0} N={1} elapsed_ms={2} lines_per_sec={3}" -f $Mark, $N, [int]$sw.Elapsed.TotalMilliseconds, [int]($N / [Math]::Max(1, $sw.Elapsed.TotalSeconds)))
[System.IO.File]::AppendAllText((Join-Path $ProjectRoot 'logs\_benchresult.txt'), $r + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
Write-Host $r
