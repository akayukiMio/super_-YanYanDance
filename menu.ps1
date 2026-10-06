<#
.SYNOPSIS
    交互式菜单：日常所有操作都在这里选数字完成（可双击 start.cmd 启动）。
.DESCRIPTION
    菜单封装了 sync / run_all / audit / maint 的常用组合，涉及视频的操作会先自动做网络自检
    （视频分片主机直连不通，需要系统代理）。
    想要浏览器界面（同样的 16 项 + 实时日志面板）：双击 start-web.cmd，或按本菜单的 17。
#>

$root = $PSScriptRoot
. (Join-Path $root 'config.ps1')
Set-NetBaseline   # 设 UTF-8 控制台编码（否则中文菜单会乱码）+ TLS/连接数基线

$Maint = Join-Path $root 'tools\maint.ps1'
$Dedupe = Join-Path $root 'tools\dedupe.ps1'
$Sync  = Join-Path $root 'sync.ps1'
$Run   = Join-Path $root 'run_all.ps1'
$Audit = Join-Path $root 'audit.ps1'

function Pause-It {
    Write-Host ''
    Write-Host '── 按回车返回菜单 ──' -ForegroundColor DarkGray
    Read-Host | Out-Null
}

function Read-YYMM {
    $y = (Read-Host '  年份两位 (如 26)').Trim()
    $m = (Read-Host '  月份两位 (如 08)').Trim()
    if ($y -notmatch '^\d{2}$' -or $m -notmatch '^\d{2}$') {
        Write-Host '  输入格式不正确，已取消' -ForegroundColor Yellow
        return $null
    }
    return @($y, $m)
}

while ($true) {
    Write-Host ''
    Write-Host '╔══════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
    Write-Host '║                     画廊搬运工具  ·  操作菜单             ║' -ForegroundColor Cyan
    Write-Host '╚══════════════════════════════════════════════════════════╝' -ForegroundColor Cyan

    # 顶部状态条
    $baseN = @([System.IO.Directory]::GetFiles($Cfg.BaselineDir, '*.html')).Count
    $pendN = 0
    if ([System.IO.File]::Exists($Cfg.PendingFile)) {
        $pendN = @([System.IO.File]::ReadAllLines($Cfg.PendingFile) | Where-Object { $_.Trim() }).Count
    }
    Write-Host ("  基线项目 {0} 个 | 待处理 {1} 项 | 产物目录 {2}" -f $baseN, $pendN, $Cfg.OutDir) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  【日常】' -ForegroundColor Yellow
    Write-Host '   1) 一键增量搬运（拉取仓库→识别新增→下载图片+视频→回收 pending）'
    Write-Host '   2) 只看上游有无更新（不下载、不写盘）'
    Write-Host '   3) 网络连通性自检（判断是否需要开代理）'
    Write-Host ''
    Write-Host '  【补漏】' -ForegroundColor Yellow
    Write-Host '   4) 重试 pending 中未完成的项目'
    Write-Host '   5) 补某个月的图片'
    Write-Host '   6) 补某个月的视频'
    Write-Host ''
    Write-Host '  【核对】' -ForegroundColor Yellow
    Write-Host '   7) 全量体检（所有月份）'
    Write-Host '   8) 单月体检'
    Write-Host '   9) 项目状态速览'
    Write-Host '  10) 列举“HTML 还在、图库里已被我删掉”的项目（只盘点，不恢复）'
    Write-Host ''
    Write-Host '  【维护】' -ForegroundColor Yellow
    Write-Host '  11) 清理库里的重复项目（同一画廊被重下成两份，先预览后确认）'
    Write-Host '  12) 停止正在运行的下载任务'
    Write-Host '  13) 清理 ts 残留'
    Write-Host '  14) 打开产物目录'
    Write-Host '  15) 创建桌面快捷方式'
    Write-Host '  16) 打开项目文档 PROJECT.md'
    Write-Host '  17) 启动 Web 控制台并在浏览器打开（内网页面版的全套菜单，需已装 node）' -ForegroundColor Green
    Write-Host ''
    Write-Host '   q) 退出' -ForegroundColor DarkGray
    Write-Host ''

    $c = (Read-Host '  请选择').Trim().ToLower()

    switch ($c) {

    '1' {
        Write-Host ''
        Write-Host '── 开跑前先做网络自检 ──' -ForegroundColor DarkCyan
        & $Maint -Action NetCheck
        Write-Host ''
        $go = (Read-Host '  继续执行一键增量搬运？(Y/n)').Trim().ToLower()
        if ($go -eq '' -or $go -eq 'y') { & $Sync -Run -Quiet }
        Pause-It
    }

    '2' { & $Sync -DryRun; Pause-It }

    '3' { & $Maint -Action NetCheck; Pause-It }

    '4' {
        $pend = @()
        if ([System.IO.File]::Exists($Cfg.PendingFile)) {
            $pend = @([System.IO.File]::ReadAllLines($Cfg.PendingFile) | Where-Object { $_.Trim() })
        }
        if ($pend.Count -eq 0) { Write-Host '  pending 为空，没有待重试项' -ForegroundColor Green; Pause-It; break }
        Write-Host ("  待重试 {0} 项：" -f $pend.Count) -ForegroundColor Cyan
        foreach ($x in $pend) { Write-Host ("     - {0}" -f $x) }
        & $Maint -Action NetCheck
        & $Run -ListFile $Cfg.PendingFile
        Pause-It
    }

    '5' {
        $ym = Read-YYMM
        if ($ym) { & $Run -Year $ym[0] -Month $ym[1] -ImagesOnly -Quiet }
        Pause-It
    }

    '6' {
        $ym = Read-YYMM
        if ($ym) {
            & $Maint -Action NetCheck
            & $Run -Year $ym[0] -Month $ym[1] -VideosOnly
        }
        Pause-It
    }

    '7' { & $Audit -All; Pause-It }

    '8' {
        $ym = Read-YYMM
        if ($ym) { & $Audit -Year $ym[0] -Month $ym[1] }
        Pause-It
    }

    '9'  { & $Maint -Action Status; Pause-It }

    '10' { & $Maint -Action MissingOut; Pause-It }

    '11' {
        & $Dedupe                       # 先预览（不删任何东西）
        Write-Host ''
        $ok = (Read-Host '  确认删除以上重复项目？输入 YES 执行').Trim()
        if ($ok -ceq 'YES') { & $Dedupe -Apply } else { Write-Host '  已取消，未删除任何文件' -ForegroundColor Yellow }
        Pause-It
    }

    '12' { & $Maint -Action Kill; Pause-It }
    '13' { & $Maint -Action CleanTs; Pause-It }
    '14' { Start-Process explorer.exe -ArgumentList $Cfg.OutDir }

    '15' {
        try {
            $ws = New-Object -ComObject WScript.Shell
            $desktop = [Environment]::GetFolderPath('Desktop')
            $lnkPath = Join-Path $desktop '画廊搬运台.lnk'
            $lnk = $ws.CreateShortcut($lnkPath)
            $lnk.TargetPath = (Join-Path $root 'start.cmd')
            $lnk.WorkingDirectory = $root
            $lnk.Description = '画廊搬运台 · 控制台菜单'
            $lnk.Save()
            Write-Host ("  已创建桌面快捷方式: {0}" -f $lnkPath) -ForegroundColor Green
        } catch {
            Write-Host ("  创建失败: {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
        Pause-It
    }

    '16' {
        $doc = Join-Path $root 'PROJECT.md'
        if ([System.IO.File]::Exists($doc)) { Start-Process $doc } else { Write-Host '  未找到 PROJECT.md' -ForegroundColor Yellow }
    }

    '17' {
        $launcher = Join-Path $root 'start-web.cmd'
        if (-not [System.IO.File]::Exists($launcher)) { Write-Host '  未找到 start-web.cmd' -ForegroundColor Yellow; Pause-It; break }
        if (-not (Get-Command node.exe -ErrorAction SilentlyContinue)) { Write-Host '  未检测到 node（Web 控制台需要）；控制台菜单仍可用' -ForegroundColor Yellow; Pause-It; break }
        # /min：服务日志另开一个最小化窗口，关掉那个窗口即停服务
        Start-Process $launcher -WorkingDirectory $root -WindowStyle Minimize | Out-Null
        Write-Host '  已启动 Web 服务，稍候浏览器会自动打开 http://127.0.0.1:8787/' -ForegroundColor Green
        Pause-It
    }

    'q' { Write-Host '  再见'; return }

    default { Write-Host '  无效选择' -ForegroundColor Yellow }

    }
}
