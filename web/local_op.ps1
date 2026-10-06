<#
.SYNOPSIS
    本机操作助手：对应旧控制台菜单的 14（打开产物目录）/ 15（桌面快捷方式）/ 16（打开文档）。
.DESCRIPTION
    浏览器无法碰本地文件系统，所以这些动作由本机上的 Web 服务代跑一层。
    只接受固定的 -What 枚举值，路径全部取自 config.ps1，不接受调用方拼命令。
    注意：正因为这个脚本会在本机开程序，web/server.mjs 只绑 127.0.0.1；要开局域网必须先加鉴权。
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('outdir', 'logdir', 'doc', 'shortcut')]
    [string]$What,
    [string]$Path = ''
)

$ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $ProjectRoot 'config.ps1')

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Utf8NoBom

function Open-Target([string]$target) {
    if (-not $target) { Write-Host '[local] 未给出路径' -ForegroundColor Yellow; return }
    # 坑：PS 5.1 跑在 .NET Framework 上，[System.IO.Path]::Exists 根本不存在（那是 .NET Core 才有的）。
    # 误用它抛的是非终止错，句子会被跳过 -> 判存形同虚设，而且控制台多一行莫名其妙的报错。
    $exists = [System.IO.Directory]::Exists($target) -or [System.IO.File]::Exists($target)
    if (-not $exists) {
        Write-Host ("[local] 路径不存在: {0}" -f $target) -ForegroundColor Yellow
        return
    }
    # 坑 9：Start-Process -ArgumentList 不会自动加引号，含空格的路径必须自己包
    Start-Process explorer.exe -ArgumentList ('"' + $target + '"') | Out-Null
    Write-Host ("[local] 已交给系统打开: {0}" -f $target)
}

switch ($What) {
    'outdir' { Open-Target $Cfg.OutDir }
    'logdir' { Open-Target $Cfg.LogDir }
    'doc'    { Open-Target $(if ($Path) { $Path } else { Join-Path $ProjectRoot 'PROJECT.md' }) }

    'shortcut' {
        try {
            $ws = New-Object -ComObject WScript.Shell
            $desktop = [Environment]::GetFolderPath('Desktop')
            $lnkPath = Join-Path $desktop '画廊搬运台 Web.lnk'
            $lnk = $ws.CreateShortcut($lnkPath)
            $lnk.TargetPath = (Join-Path $ProjectRoot 'start-web.cmd')
            $lnk.WorkingDirectory = $ProjectRoot
            $lnk.Description = '启动画廊搬运台 Web 控制台并在浏览器打开'
            # 图标：由 tools\make_icon.ps1 生成（换图 = 重跑那个脚本 + 重点一次本按钮）
            $ico = Join-Path $PSScriptRoot 'assets\app.ico'
            if ([System.IO.File]::Exists($ico)) {
                # IconLocation 的格式是 `路径,索引`。给路径包双引号会让 shell 解析失败，
                # 默默退回默认图标（实测：带引号时 ExtractAssociatedIcon(.lnk) 返回一片 FAFAFA）。
                # 只有真含空格时才加引号。
                $icoLoc = if ($ico -match '\s') { ('"{0}",0' -f $ico) } else { ('{0},0' -f $ico) }
                $lnk.IconLocation = $icoLoc
            }
            $lnk.WindowStyle = 7   # 7 = 最小化：服务日志窗口不抢屏，浏览器起来就是主角
            $lnk.Save()
            Write-Host ("[local] 已创建桌面快捷方式: {0}" -f $lnkPath)
            Write-Host ("[local] 图标: {0}" -f $lnk.IconLocation)
            if (-not [System.IO.File]::Exists($ico)) { Write-Host ('[local] 未找到图标，用了默认图标: ' + $ico) -ForegroundColor Yellow }
        } catch {
            Write-Host ("[local] 创建失败: {0}" -f $_.Exception.Message) -ForegroundColor Red
            exit 1
        }
    }
}
