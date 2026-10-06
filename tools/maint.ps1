<#
.SYNOPSIS
    日常维护多功能工具：语法检查 / 进程管理 / ts 清理 / URL 探测 / 状态速览 / 网络自检 / 被删项盘点。
.EXAMPLE
    .\tools\maint.ps1 -Action Status
    .\tools\maint.ps1 -Action Syntax                      # 检查全部 .ps1
    .\tools\maint.ps1 -Action Syntax -Path ..\run_all.ps1 # 检查单个
    .\tools\maint.ps1 -Action List                        # 列出本项目在跑的进程
    .\tools\maint.ps1 -Action Kill                        # 停掉它们（含视频子进程）
    .\tools\maint.ps1 -Action CleanTs                     # 清理产物目录残留 .ts
    .\tools\maint.ps1 -Action NetCheck                    # 四个关键主机连通性自检
    .\tools\maint.ps1 -Action MissingOut                  # 列举 HTML 在库但产物文件夹已被我删掉的项目
#>
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Status','Syntax','List','Kill','CleanTs','ProbeUrl','NetCheck','MissingOut')]
    [string]$Action,
    [string]$Path = '',
    [string]$Url = '',
    [switch]$Deep
)

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'config.ps1')
Set-NetBaseline

function Get-ProjProcs {
    return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
        $_.CommandLine -and (
            $_.CommandLine -like '*run_all.ps1*' -or $_.CommandLine -like '*download_video_worker.ps1*' -or
            $_.CommandLine -like '*sync.ps1*' -or $_.CommandLine -like '*audit.ps1*'
        )
    })
}

function Probe-Status($u) {
    try {
        $req = [System.Net.HttpWebRequest]::Create($u)
        $req.Timeout = 20000; $req.ReadWriteTimeout = 20000; $req.UserAgent = 'Mozilla/5.0'
        $resp = $req.GetResponse(); $len = $resp.ContentLength; $code = [int]$resp.StatusCode; $resp.Close()
        return ("HTTP {0}  {1} bytes" -f $code, $len)
    } catch [System.Net.WebException] {
        $r = $_.Exception.Response
        if ($r) { return ("HTTP {0}" -f [int]$r.StatusCode) }
        return ('无响应: ' + $_.Exception.Message)
    } catch { return ('异常: ' + $_.Exception.Message) }
}

switch ($Action) {

'Status' {
    $baseN = @([System.IO.Directory]::GetFiles($Cfg.BaselineDir, '*.html')).Count
    $manN = 0; if ([System.IO.File]::Exists($Cfg.Manifest)) { $manN = @(Import-Csv -LiteralPath $Cfg.Manifest).Count }
    $pendN = 0; if ([System.IO.File]::Exists($Cfg.PendingFile)) { $pendN = @([System.IO.File]::ReadAllLines($Cfg.PendingFile) | Where-Object { $_.Trim() }).Count }
    $outD = @([System.IO.Directory]::GetDirectories($Cfg.OutDir))
    $bytes = 0; $nfiles = 0
    foreach ($d in $outD) { foreach ($f in [System.IO.Directory]::GetFiles($d)) { $nfiles++; $bytes += (New-Object System.IO.FileInfo $f).Length } }
    $repoState = if ([System.IO.Directory]::Exists((Join-Path $Cfg.RepoDir '.git'))) { 'yes' } else { 'no' }
    Write-Host '===== 项目状态 ====='
    Write-Host ("  项目根目录 : {0}" -f $Cfg.ProjectDir)
    Write-Host ("  产物目录   : {0}" -f $Cfg.OutDir)
    Write-Host ("  上游仓库   : {0}  (已 clone: {1})" -f $Cfg.RepoUrl, $repoState)
    Write-Host ("  基线 HTML  : {0}" -f $baseN)
    Write-Host ("  manifest   : {0} 行" -f $manN)
    Write-Host ("  pending    : {0} 条" -f $pendN)
    Write-Host ("  产物       : {0} 个项目 / {1} 个文件 / {2} GB" -f $outD.Count, $nfiles, [math]::Round($bytes/1GB,2))
    $procs = Get-ProjProcs
    Write-Host ("  在跑进程   : {0}" -f $procs.Count)
}

'Syntax' {
    $targets = @()
    if ($Path) { $targets = @((Resolve-Path -LiteralPath $Path).Path) }
    else { $targets = @([System.IO.Directory]::GetFiles($root, '*.ps1', [System.IO.SearchOption]::AllDirectories) | Where-Object { $_ -notlike '*\repo\*' }) }
    $bad = 0
    foreach ($t in $targets) {
        $errs = $null
        [void][System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $t), [ref]$errs)
        if ($errs -and $errs.Count -gt 0) {
            $bad++
            Write-Host ("  [FAIL] {0}" -f [System.IO.Path]::GetFileName($t)) -ForegroundColor Red
            foreach ($e in $errs) { Write-Host ("      line {0}: {1}" -f $e.Token.StartLine, $e.Message) }
        } else {
            Write-Host ("  [OK]   {0}" -f [System.IO.Path]::GetFileName($t)) -ForegroundColor Green
        }
    }
    Write-Host ("语法检查: {0} 个文件，{1} 个有问题" -f $targets.Count, $bad)
}

'List' {
    $procs = Get-ProjProcs
    if ($procs.Count -eq 0) { Write-Host '本项目无运行中进程' }
    foreach ($p in $procs) { Write-Host ("  pid {0}  {1}" -f $p.ProcessId, $p.CommandLine) }
}

'Kill' {
    $procs = Get-ProjProcs
    if ($procs.Count -eq 0) { Write-Host '本项目无运行中进程' }
    foreach ($p in $procs) {
        try { Stop-Process -Id $p.ProcessId -Force; Write-Host ("  killed pid {0}" -f $p.ProcessId) } catch { Write-Host ("  失败 pid {0}: {1}" -f $p.ProcessId, $_.Exception.Message) }
    }
}

'CleanTs' {
    # ts 只是视频中间件；正常流程转 mp4 后即删。此处清理中断残留
    $n = 0; $bytes = 0
    foreach ($d in [System.IO.Directory]::GetDirectories($Cfg.OutDir)) {
        foreach ($f in [System.IO.Directory]::GetFiles($d, '*.ts')) {
            $fi = New-Object System.IO.FileInfo $f
            $bytes += $fi.Length
            Remove-Item -LiteralPath $f -Force
            $n++
        }
    }
    Write-Host ("已清理残留 ts: {0} 个 / {1} MB" -f $n, [math]::Round($bytes/1MB,1))
}

'NetCheck' {
    # 开跑前连通性自检：探测 config.local.ps1 里声明的关键主机
    # 判定原则：拿到任何 HTTP 响应（包括 404）= 可达；超时/连接失败 = 不可达
    # 主机清单不写在本文件里（它含来源信息）；判定按稳定的 K 键，不要改成按主机名匹配
    $targets = @($Cfg.NetTargets)
    Write-Host '===== 网络连通性自检 ====='
    if ($targets.Count -eq 0) {
        Write-Host '  未配置探测目标：复制 config.local.example.ps1 为 config.local.ps1 并填 $Cfg["NetTargets"]' -ForegroundColor Yellow
        return
    }
    $bad = @()
    foreach ($t in $targets) {
        $reach = $false; $detail = ''
        try {
            $req = [System.Net.HttpWebRequest]::Create($t.U)
            $req.Timeout = 12000; $req.ReadWriteTimeout = 12000; $req.UserAgent = 'Mozilla/5.0'
            $resp = $req.GetResponse(); $detail = ('HTTP ' + [int]$resp.StatusCode); $resp.Close(); $reach = $true
        } catch [System.Net.WebException] {
            $r = $_.Exception.Response
            if ($r) { $detail = ('HTTP ' + [int]$r.StatusCode); $reach = $true }
            else { $detail = ('不可达: ' + $_.Exception.Message) }
        } catch { $detail = ('异常: ' + $_.Exception.Message) }
        $mark = if ($reach) { '[可达]  ' } else { '[不可达]' }
        $col  = if ($reach) { 'Green' } else { 'Red' }
        Write-Host ("  {0} {1,-12} {2}" -f $mark, $t.N, $detail) -ForegroundColor $col
        if (-not $reach) { $bad += $t.K }
    }
    Write-Host ''
    if ($bad -contains 'repo') { Write-Host '  → 上游仓库不可达：sync.ps1 无法拉取更新（先开代理）' -ForegroundColor Yellow }
    if ($bad -contains 'img')  { Write-Host '  → 图床不可达：图片下载会全失败（先开代理）' -ForegroundColor Yellow }
    if ($bad -contains 'list') { Write-Host '  → 视频列表主机不可达：m3u8 拉不到，视频无法下载' -ForegroundColor Yellow }
    if ($bad -contains 'seg')  { Write-Host '  → 视频分片主机不可达：视频会卡在“Unable to connect”，**需开启系统代理**（已验证）' -ForegroundColor Yellow }
    if ($bad.Count -eq 0) { Write-Host '  → 全部可达，可以放心开跑' -ForegroundColor Green }
}

'MissingOut' {
    # 基线 HTML 还在、但产物文件夹已被删除/清空的项目清单
    # 只盘点不恢复：一键增量搬运只处理 pending 里的新项目，绝不会把这些旧项目重新下载回来
    $man = @{}
    if ([System.IO.File]::Exists($Cfg.Manifest)) {
        foreach ($r in @(Import-Csv -LiteralPath $Cfg.Manifest)) { if (-not $man.ContainsKey($r.datedName)) { $man[$r.datedName] = $r } }
    }
    $imgExts = @('.jpg','.jpeg','.png','.gif','.webp')
    $rows = @()
    $htmls = @([System.IO.Directory]::GetFiles($Cfg.BaselineDir, '*.html') | Sort-Object)
    foreach ($hf in $htmls) {
        $bn = [System.IO.Path]::GetFileNameWithoutExtension($hf)
        $d = Join-Path $Cfg.OutDir $bn
        $nImg = 0; $nVid = 0
        if ([System.IO.Directory]::Exists($d)) {
            foreach ($f in [System.IO.Directory]::GetFiles($d)) {
                $e = [System.IO.Path]::GetExtension($f).ToLower()
                if ($imgExts -contains $e) { $nImg++ } elseif ($e -eq '.mp4') { $nVid++ }
            }
            if (($nImg + $nVid) -gt 0) { continue }   # 有媒体文件就算项目还在，细节缺失交给 audit
            $state = '空壳(无图无视频)'
        } else { $state = '文件夹不存在' }
        $g = Parse-Gallery ([System.IO.File]::ReadAllText($hf, [System.Text.Encoding]::UTF8))
        $firstSeen = ''
        if ($man.ContainsKey($bn)) { $firstSeen = $man[$bn].firstSeen }
        $rows += [pscustomobject]@{ Name=$bn; State=$state; ImgExp=$g.Imgs.Count; VidExp=$g.Vids.Count; FirstSeen=$firstSeen }
    }
    Write-Host ("===== HTML 在库、产物已被删除的项目  (共扫描 {0} 个基线项目) =====" -f $htmls.Count)
    if ($rows.Count -eq 0) {
        Write-Host '  无：每个基线 HTML 都还有对应的产物文件夹' -ForegroundColor Green
    } else {
        Write-Host ("  {0,-62} {1,-16} {2,6} {3,6} {4,12}" -f '项目', '状态', '应有图', '应有视', '首次入库') -ForegroundColor Cyan
        foreach ($r in $rows) {
            Write-Host ("  {0,-62} {1,-16} {2,6} {3,6} {4,12}" -f $r.Name, $r.State, $r.ImgExp, $r.VidExp, $r.FirstSeen)
        }
        Write-Host ''
        Write-Host ("  合计 {0} 个项目只剩 HTML、没有图片/视频。它们不会被一键增量搬运恢复。" -f $rows.Count) -ForegroundColor Yellow
        Write-Host '  确实需要重新下载时： .\run_all.ps1 -ListFile <包含该项目名的清单文件>' -ForegroundColor DarkGray
    }
    $rep = Join-Path $Cfg.LogDir 'missing_out.txt'
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(("MissingOut {0}   基线: {1}   产物: {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $Cfg.BaselineDir, $Cfg.OutDir))
    foreach ($r in $rows) { [void]$sb.AppendLine(("{0}`t{1}`t图{2}`t视{3}`t{4}" -f $r.Name, $r.State, $r.ImgExp, $r.VidExp, $r.FirstSeen)) }
    [System.IO.File]::WriteAllText($rep, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    Write-Host ("  报告: {0}" -f $rep) -ForegroundColor DarkGray
}

'ProbeUrl' {
    if (-not $Url) { Write-Host '需要 -Url 参数' -ForegroundColor Yellow; return }
    Write-Host ("  {0}" -f $Url)
    Write-Host ("     -> {0}" -f (Probe-Status $Url))
    if ($Deep -and $Url -like '*.m3u8*') {
        try {
            $wc = New-Object System.Net.WebClient; $wc.Headers.Add('User-Agent','Mozilla/5.0')
            $pl = $wc.DownloadString($Url)
            $sg = @($pl -split "`r?`n" | Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') })
            Write-Host ("  分片数: {0}" -f $sg.Count)
            $idx = @(0); if ($sg.Count -gt 1) { $idx += ($sg.Count - 1) }
            foreach ($i in $idx) {
                $su = (New-Object System.Uri([System.Uri]$Url, $sg[$i].Trim())).AbsoluteUri
                Write-Host ("     [{0}] {1}" -f ($i+1), $su)
                Write-Host ("         -> {0}" -f (Probe-Status $su))
            }
            Write-Host '  提示: m3u8 返回 200 不代表可下载，必须分片也 200' -ForegroundColor DarkGray
        } catch { Write-Host ('  取列表失败: ' + $_.Exception.Message) -ForegroundColor Red }
    }
}

}
