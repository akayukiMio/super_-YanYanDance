<#
.SYNOPSIS
    查当前是否已有本工具的重活脚本在跑（run_all / sync / audit / dedupe / run_job），输出 JSON。
.DESCRIPTION
    存在的理由：Web 服务里的“同时只允许一个任务”是**进程内**的锁。历史上端口被占会自动顺延，
    于是同一台机器上可能同时开着好几个 Web 实例，各自都有自己的锁 → 真的会并发跑两份下载，
    而源站对并发极敏感（PROJECT.md 坑 4/12：突发请求会让主机进入分钟级冷却，越跑越慢）。
    这个脚本给服务端当“跨进程锁”用：只要系统里存在下列脚本的 powershell 进程，就拒绝再起新任务。
    判据与 tools\maint.ps1 的 Get-ProjProcs 一致（按命令行匹配），额外把 run_job.ps1 也算进来，
    因为 Web 任务是通过它调起引擎的，父进程命令行里只有 run_job.ps1。
#>
$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Utf8NoBom

$names = @('run_all.ps1', 'sync.ps1', 'audit.ps1', 'run_job.ps1', 'dedupe.ps1')
# 命令行里“包含”即可：-File x.ps1 后面还会跟一串参数，不能用后缀匹配
$hits = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
    $cl = $_.CommandLine
    if (-not $cl) { return $false }
    foreach ($p in $names) { if ($cl -like ('*' + $p + '*')) { return $true } }
    return $false
})

$rows = @()
foreach ($h in $hits) {
    $name = ''
    foreach ($p in $names) {
        if ($h.CommandLine -like ('*' + $p + '*')) { $name = $p; break }
    }
    $rows += [ordered]@{ pid = [int]$h.ProcessId; script = $name; started = $h.CreationDate.ToString('yyyy-MM-dd HH:mm:ss') }
}

$out = [ordered]@{ busy = $rows.Count; procs = $rows; self = $PID }
[Console]::Out.Write((ConvertTo-Json -InputObject $out -Compress))
