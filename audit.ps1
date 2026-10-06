<#
.SYNOPSIS
    产物齐全性 + 完整性体检（项目级 / 图片级 / 视频级 / 内容级），支持单月或全量。
.DESCRIPTION
    以 repo_html 基线 HTML 为真值，比对 OutDir 中的产物：
      项目级：每个 HTML 是否有同名产物文件夹
      图片级：唯一正片图数 vs 文件夹内图片数（jpg/png/gif/webp）
      视频级：唯一 m3u8 数（剔除黑名单）vs mp4 数
      内容级：图片魔数、mp4 的 ftyp 头、零字节文件、ts 残留
    state\deadlinks.txt 中已确认的死链会被豁免（计入"已知死链"而非异常）。
.PARAMETER All
    自动发现基线中所有 [YY-MM] 月份并逐月体检，最后给出总表。
.PARAMETER ProbeDead
    对缺口逐个实地探测源 URL，区分"死链(4xx)"与"可补(200)"。
    注意：仅适合残差少量缺口；整月未下载时会产生上千次请求，非常慢。
.EXAMPLE
    .\audit.ps1 -Year 26 -Month 08
    .\audit.ps1 -All
    .\audit.ps1 -Year 25 -Month 10 -ProbeDead
#>
param(
    [string]$Year = '',
    [string]$Month = '',
    [switch]$All,
    [switch]$ProbeDead
)

. (Join-Path $PSScriptRoot 'config.ps1')
Set-NetBaseline

# 已确认死链（豁免用）
$deadSet = @{}
if ([System.IO.File]::Exists($Cfg.DeadLinks)) {
    foreach ($l in [System.IO.File]::ReadAllLines($Cfg.DeadLinks)) { $t = $l.Trim(); if ($t) { $deadSet[$t] = $true } }
}

function Probe-Status($url) {
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Timeout = 20000; $req.ReadWriteTimeout = 20000; $req.UserAgent = 'Mozilla/5.0'
        $resp = $req.GetResponse(); $code = [int]$resp.StatusCode; $resp.Close(); return $code
    } catch [System.Net.WebException] {
        $r = $_.Exception.Response
        if ($r) { return [int]$r.StatusCode }
        return -1
    } catch { return -1 }
}

$imgExt = @('.jpg','.jpeg','.png','.gif','.webp')

function Audit-Month {
    param([string]$YY, [string]$MM)
    $Prefix = "[{0}-{1}-" -f $YY, $MM
    $Out = Join-Path $Cfg.LogDir ("audit_{0}{1}.txt" -f $YY, $MM)
    $sb = New-Object System.Text.StringBuilder
    $htmls = @([System.IO.Directory]::GetFiles($Cfg.BaselineDir, '*.html') |
               Where-Object { [System.IO.Path]::GetFileNameWithoutExtension($_).StartsWith($Prefix) } | Sort-Object)

    [void]$sb.AppendLine(("{0} 体检报告   基线: {1}   产物: {2}" -f $Prefix, $Cfg.BaselineDir, $Cfg.OutDir))
    [void]$sb.AppendLine(("项目数: {0}   已知死链库: {1} 条" -f $htmls.Count, $deadSet.Count))
    [void]$sb.AppendLine('=' * 100)

    $okProj = 0; $missProj = @(); $imgBad = @(); $vidBad = @(); $badFile = @(); $tsLeft = @(); $deadKnown = @(); $revivable = @()
    $tImgExp = 0; $tImgGot = 0; $tVidExp = 0; $tVidGot = 0

    foreach ($h in $htmls) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($h)
        $g = Parse-Gallery ([System.IO.File]::ReadAllText($h, [System.Text.Encoding]::UTF8))
        $imgs = $g.Imgs; $vids = $g.Vids
        $tImgExp += $imgs.Count; $tVidExp += $vids.Count

        $dir = Join-Path $Cfg.OutDir $base
        if (-not [System.IO.Directory]::Exists($dir)) {
            $missProj += ("{0}  (应有 图{1}/视{2})" -f $base, $imgs.Count, $vids.Count)
            [void]$sb.AppendLine(("  [缺项目] {0}" -f $base)); continue
        }
        $okProj++

        $nImg = 0; $nVid = 0; $nTs = 0; $flags = ''
        foreach ($f in [System.IO.Directory]::GetFiles($dir)) {
            $e = [System.IO.Path]::GetExtension($f).ToLower(); $fname = [System.IO.Path]::GetFileName($f)
            $fs = [System.IO.File]::OpenRead($f)
            try { $buf = New-Object byte[] 32; $read = $fs.Read($buf, 0, 32) } finally { $fs.Close() }
            $hex = ''; for ($i = 0; $i -lt [math]::Min(8, $read); $i++) { $hex += $buf[$i].ToString('X2') }
            $ascii = [System.Text.Encoding]::ASCII.GetString($buf, 0, $read)
            if ($read -le 0) { $badFile += ("零字节 {0}\{1}" -f $base, $fname); $flags = 'X'; continue }
            if ($imgExt -contains $e) {
                $nImg++
                $okHead = ($e -in @('.jpg','.jpeg') -and $hex.StartsWith('FFD8FF')) -or ($e -eq '.png' -and $hex.StartsWith('89504E47')) -or
                          ($e -eq '.gif' -and $hex.StartsWith('47494638')) -or ($e -eq '.webp' -and $hex.StartsWith('52494646'))
                if (-not $okHead) { $badFile += ("图片魔数异常 {0}\{1} head={2}" -f $base, $fname, $hex); $flags = 'X' }
            } elseif ($e -eq '.mp4') {
                $nVid++
                if ($ascii -notmatch 'ftyp') { $badFile += ("mp4 头异常 {0}\{1}" -f $base, $fname); $flags = 'X' }
            } elseif ($e -eq '.ts') { $nTs++ }
        }
        $tImgGot += $nImg; $tVidGot += $nVid

        # ---- 图片缺口 ----
        if ($nImg -lt $imgs.Count) {
            $missI = @()
            for ($ii = 1; $ii -le $imgs.Count; $ii++) {
                $nm = "{0:D4}" -f $ii; $found = $false
                foreach ($e2 in $imgExt) { if ([System.IO.File]::Exists((Join-Path $dir ($nm + $e2)))) { $found = $true; break } }
                if (-not $found) { $missI += $ii }
            }
            $nDeadKnown = 0; $nLive = 0; $nUnprobed = 0
            foreach ($mi in $missI) {
                $u = $imgs[$mi-1]
                if ($deadSet.ContainsKey($u)) { $nDeadKnown++; continue }
                if ($ProbeDead) {
                    $c = Probe-Status $u
                    if ($c -ge 200 -and $c -lt 300) { $nLive++; $revivable += ("图 {0}\{1:D4} <- {2}" -f $base, $mi, $u) }
                    else { $nDeadKnown++; $deadKnown += ("图 {0}\{1:D4} HTTP {2} <- {3}" -f $base, $mi, $c, $u) }
                } else { $nUnprobed++ }
            }
            $tag = if ($nUnprobed -gt 0) { '待判定' } else { '已知死链' }
            $imgBad += ("{0}  图 {1}/{2} (缺 {3}: {4} {5}{6})" -f $base, $nImg, $imgs.Count, $missI.Count, $tag, $nDeadKnown, $(if($nLive){" / 可补 $nLive"}else{''}))
            if ($nUnprobed -eq 0 -and $nLive -eq 0) { $flags = 'D' } else { $flags = 'X' }
        }
        # ---- 视频缺口 ----
        if ($nVid -lt $vids.Count) {
            $missV = @()
            for ($vi = 1; $vi -le $vids.Count; $vi++) {
                if (-not [System.IO.File]::Exists((Join-Path $dir ("video_{0:D2}.mp4" -f $vi)))) { $missV += $vi }
            }
            $nDeadKnown = 0; $nLive = 0; $nUnprobed = 0
            foreach ($mv in $missV) {
                $u = $vids[$mv-1]
                if ($deadSet.ContainsKey($u)) { $nDeadKnown++; continue }
                if ($ProbeDead) {
                    # m3u8 返回 200 不代表可下：必须穿透到首个分片
                    $c = Probe-Status $u; $segOk = $false
                    if ($c -ge 200 -and $c -lt 300) {
                        try {
                            $wc = New-Object System.Net.WebClient; $wc.Headers.Add('User-Agent','Mozilla/5.0')
                            $pl = $wc.DownloadString($u)
                            $sg = @($pl -split "`r?`n" | Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') })
                            if ($sg.Count -gt 0) {
                                $su = (New-Object System.Uri([System.Uri]$u, $sg[0].Trim())).AbsoluteUri
                                $sc = Probe-Status $su; $segOk = ($sc -ge 200 -and $sc -lt 300)
                            }
                        } catch { $segOk = $false }
                    }
                    if ($segOk) { $nLive++; $revivable += ("视频 {0}\video_{1:D2} <- {2}" -f $base, $mv, $u) }
                    else { $nDeadKnown++; $deadKnown += ("视频 {0}\video_{1:D2} 列表/分片不可用 <- {2}" -f $base, $mv, $u) }
                } else { $nUnprobed++ }
            }
            $tag = if ($nUnprobed -gt 0) { '待判定' } else { '已知死链' }
            $vidBad += ("{0}  视频 {1}/{2} (缺 {3}: {4} {5}{6})" -f $base, $nVid, $vids.Count, $missV.Count, $tag, $nDeadKnown, $(if($nLive){" / 可补 $nLive"}else{''}))
            if ($nUnprobed -eq 0 -and $nLive -eq 0) { $flags = 'D' } else { $flags = 'X' }
        }
        if ($nTs -gt 0) { $tsLeft += ("{0}  残留 ts {1} 个" -f $base, $nTs); $flags = 'X' }

        $st = switch ($flags) { 'X' {'异常'} 'D' {'死链'} default {'OK  '} }
        [void]$sb.AppendLine(("  [{0}] {1}  图 {2}/{3}  视频 {4}/{5}" -f $st, $base, $nImg, $imgs.Count, $nVid, $vids.Count))
    }

    [void]$sb.AppendLine('=' * 100)
    [void]$sb.AppendLine(("项目: {0}/{1} (缺 {2}) | 图片 {3}/{4} | 视频 {5}/{6}" -f $okProj, $htmls.Count, $missProj.Count, $tImgGot, $tImgExp, $tVidGot, $tVidExp))
    [void]$sb.AppendLine(("内容异常 {0} | ts残留 {1}" -f $badFile.Count, $tsLeft.Count))
    [void]$sb.AppendLine('')
    foreach ($pair in @(@('缺失项目',$missProj), @('图片缺口',$imgBad), @('视频缺口',$vidBad), @('内容异常',$badFile), @('ts 残留',$tsLeft), @('本次确认死链',$deadKnown), @('仍可补下载',$revivable))) {
        [void]$sb.AppendLine(("{0} ({1}):" -f $pair[0], $pair[1].Count))
        foreach ($x in $pair[1]) { [void]$sb.AppendLine("   - $x") }
    }
    $hardBad = ($missProj.Count + $badFile.Count + $tsLeft.Count + $revivable.Count)
    $softBad = ($imgBad.Count + $vidBad.Count)
    $verdict = if ($hardBad -eq 0 -and $softBad -eq 0) { '齐全且完整' }
               elseif ($hardBad -eq 0) { '除源站死链外齐全（无需处理）' }
               else { '有异常需处理' }
    [void]$sb.AppendLine(('结论: ' + $verdict))
    [System.IO.File]::WriteAllText($Out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))

    return [pscustomobject]@{
        Month = ("{0}-{1}" -f $YY, $MM); Proj = ("{0}/{1}" -f $okProj, $htmls.Count)
        Img = ("{0}/{1}" -f $tImgGot, $tImgExp); Vid = ("{0}/{1}" -f $tVidGot, $tVidExp)
        Bad = $hardBad; Soft = $softBad; Verdict = $verdict; Report = $Out
    }
}

# ---------- 入口 ----------
$results = @()
if ($All) {
    $months = @{}
    foreach ($f in [System.IO.Directory]::GetFiles($Cfg.BaselineDir, '*.html')) {
        $n = [System.IO.Path]::GetFileNameWithoutExtension($f)
        if ($n -match '^\[(\d{2})-(\d{2})-\d{2}\]') { $months[($Matches[1] + '|' + $Matches[2])] = $true }
    }
    foreach ($k in ($months.Keys | Sort-Object)) {
        $p = $k.Split('|')
        Write-Host ("---- {0}-{1} ----" -f $p[0], $p[1]) -ForegroundColor Cyan
        $r = Audit-Month $p[0] $p[1]
        $results += $r
        Write-Host ("  项目 {0} | 图片 {1} | 视频 {2} | 异常 {3} | 死链缺口 {4} => {5}" -f $r.Proj, $r.Img, $r.Vid, $r.Bad, $r.Soft, $r.Verdict)
    }
    Write-Host ''
    Write-Host ('=' * 92) -ForegroundColor DarkCyan
    Write-Host ("  {0,-9} {1,-10} {2,-14} {3,-12} {4,-6} {5}" -f '月份','项目','图片','视频','异常','结论') -ForegroundColor Cyan
    Write-Host ('-' * 92) -ForegroundColor DarkGray
    foreach ($r in $results) {
        Write-Host ("  {0,-9} {1,-10} {2,-14} {3,-12} {4,-6} {5}" -f $r.Month, $r.Proj, $r.Img, $r.Vid, $r.Bad, $r.Verdict)
    }
    Write-Host ('=' * 92) -ForegroundColor DarkCyan
    Write-Host ("报告目录: {0}" -f $Cfg.LogDir)
} elseif ($Year -and $Month) {
    $r = Audit-Month $Year $Month
    Write-Host ("项目 {0} | 图片 {1} | 视频 {2} | 异常 {3} | 死链缺口 {4}" -f $r.Proj, $r.Img, $r.Vid, $r.Bad, $r.Soft)
    Write-Host ("结论: {0}" -f $r.Verdict) -ForegroundColor $(if ($r.Bad -eq 0) { 'Green' } else { 'Yellow' })
    Write-Host ("报告: {0}" -f $r.Report)
} else {
    Write-Host '用法: .\audit.ps1 -All   或   .\audit.ps1 -Year 26 -Month 08 [-ProbeDead]' -ForegroundColor Yellow
}
