<#
.SYNOPSIS
    清理产物库里"同一个画廊被重复落库"的项目（按画廊内容签名判重，不看文件名）。
.DESCRIPTION
    默认只预览（不删任何东西），加 -Apply 才真正删除。
    重复的定义：repo_html 里两个及以上 HTML 的画廊签名（标题+日期+图片URL序列+视频URL序列）完全相同，
    即上游把同一份投稿重复保存成了多个 HTML 文件，于是产物库里出现了两份一模一样的项目文件夹。
    保留方选择：产物媒体文件多者 > 无 (N) 后缀者 > 名称字典序。
    安全闸（任一不满足就整组跳过、只报告不动手）：
      1) 保留方的产物文件夹必须真实存在且有媒体文件
      2) 保留方的媒体文件数 >= 被删方（绝不删掉唯一完整的那份）
      3) 组内成员数 <= 8（异常分组一律不动）
    -Apply 时会先把 manifest.csv 备份成 state\manifest.bak.csv。
.EXAMPLE
    .\tools\dedupe.ps1          # 预览：只看会删什么
    .\tools\dedupe.ps1 -Apply   # 执行：删重复文件夹 + 基线 HTML + manifest 行
#>
param([switch]$Apply)

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'config.ps1')
Set-NetBaseline

$imgExt = @('.jpg','.jpeg','.png','.gif','.webp')

function Stat-Folder([string]$name) {
    $d = Join-Path $Cfg.OutDir $name
    $r = @{ exists=$false; media=0; img=0; vid=0; bytes=0 }
    if (-not [System.IO.Directory]::Exists($d)) { return $r }
    $r.exists = $true
    foreach ($f in [System.IO.Directory]::GetFiles($d)) {
        $e = [System.IO.Path]::GetExtension($f).ToLower()
        $r.bytes += (New-Object System.IO.FileInfo $f).Length
        if ($imgExt -contains $e) { $r.img++; $r.media++ }
        elseif ($e -eq '.mp4')    { $r.vid++; $r.media++ }
    }
    return $r
}

$log = New-Object System.Text.StringBuilder
[void]$log.AppendLine(("dedupe {0}   基线: {1}   产物: {2}" -f $(if ($Apply) {'【执行删除】'}else{'【仅预览】'}), $Cfg.BaselineDir, $Cfg.OutDir))
[void]$log.AppendLine('=' * 96)

# ---------- 1) 基线项目按画廊签名分组 ----------
$byKey = @{}
foreach ($hf in [System.IO.Directory]::GetFiles($Cfg.BaselineDir, '*.html')) {
    $bn = [System.IO.Path]::GetFileNameWithoutExtension($hf)
    $g  = Parse-Gallery ([System.IO.File]::ReadAllText($hf, [System.Text.Encoding]::UTF8))
    $k  = Get-GalleryKeyFromParsed $g
    if (-not $byKey.ContainsKey($k)) { $byKey[$k] = @() }
    $byKey[$k] += [pscustomobject]@{ Name=$bn; Imgs=$g.Imgs.Count; Vids=$g.Vids.Count; Html=$hf; Key=$k }
}
$groups = @($byKey.Keys | Where-Object { $byKey[$_].Count -gt 1 })
Write-Host ("基线项目 {0} 个，画廊签名 {1} 个，重复签名组 {2} 个" -f `
    @([System.IO.Directory]::GetFiles($Cfg.BaselineDir,'*.html')).Count, $byKey.Keys.Count, $groups.Count) -ForegroundColor Cyan

# ---------- 2) 逐组决定保留方与待删方 ----------
$victims = @()   # @{Name;Html;Bytes;Media;Reason}
$kept = 0; $freedBytes = 0; $freedMedia = 0; $skippedGroups = 0
foreach ($k in ($groups | Sort-Object)) {
    $members = @($byKey[$k] | ForEach-Object {
        $s = Stat-Folder $_.Name
        [pscustomobject]@{ Name=$_.Name; Html=$_.Html; Imgs=$_.Imgs; Vids=$_.Vids; Exists=$s.exists; Media=$s.media; Bytes=$s.bytes }
    })
    # 排序键：媒体文件数降序 → 是否带 (N) 后缀升序 → 名称升序
    $ordered = @($members | Sort-Object @{Expression={$_.Media}; Descending=$true},
                                            @{Expression={ if ($_.Name -match '\(\d+\)$') {1} else {0} }; Ascending=$true},
                                            @{Expression={$_.Name}; Ascending=$true})
    $keep = $ordered[0]
    $drop = @($ordered | Select-Object -Skip 1)

    [void]$log.AppendLine(("[签名 {0}]  保留: {1}   (媒体 {2} 个 / {3} MB)" -f $k.Substring(0,12), $keep.Name, $keep.Media, [math]::Round($keep.Bytes/1MB,1)))
    if (-not $keep.Exists -or $keep.Media -eq 0) {
        [void]$log.AppendLine('   [跳过] 保留方产物文件夹不存在或为空，删任何一份都会造成数据丢失')
        $skippedGroups++; Write-Host ("  [跳过组] {0}  (保留方无产物)" -f $keep.Name) -ForegroundColor Yellow
        continue
    }
    if ($drop.Count -gt 7) {
        [void]$log.AppendLine(("   [跳过] 组内成员异常多（{0} 个），请人工核对" -f ($drop.Count + 1)))
        $skippedGroups++; Write-Host ("  [跳过组] {0}  (成员过多)" -f $keep.Name) -ForegroundColor Yellow
        continue
    }
    foreach ($d in $drop) {
        if ($d.Media -gt $keep.Media) {
            [void]$log.AppendLine(("   [保留不删] {0}  媒体 {1} > 保留方 {2}（避免删掉更完整的一份）" -f $d.Name, $d.Media, $keep.Media))
            $skippedGroups++
            continue
        }
        $victims += [pscustomobject]@{ Name=$d.Name; Html=$d.Html; Media=$d.Media; Bytes=$d.Bytes; Keep=$keep.Name }
        $freedBytes += $d.Bytes; $freedMedia += $d.Media
        [void]$log.AppendLine(("   [待删] {0}  (媒体 {1} 个 / {2} MB)  重复于 -> {3}" -f $d.Name, $d.Media, [math]::Round($d.Bytes/1MB,1), $keep.Name))
        Write-Host ("  [重复] {0}  ({1} MB)  ==  {2}" -f $d.Name, [math]::Round($d.Bytes/1MB,1), $keep.Name) -ForegroundColor Magenta
    }
    $kept++
}

# ---------- 3) 遗留提示：产物里有 (N) 文件夹但基线没有对应 HTML ----------
$orphan = @()
foreach ($d in [System.IO.Directory]::GetDirectories($Cfg.OutDir)) {
    $n = [System.IO.Path]::GetFileName($d)
    if ($n -notmatch '\(\d+\)$') { continue }
    if (-not [System.IO.File]::Exists((Join-Path $Cfg.BaselineDir ($n + '.html')))) { $orphan += $n }
}

[void]$log.AppendLine('=' * 96)
[void]$log.AppendLine(("合计: 重复组 {0} 个 | 待删项目 {1} 个 / {2} 个媒体文件 / {3} GB" -f `
    $groups.Count, $victims.Count, $freedMedia, [math]::Round($freedBytes/1GB,2)))
[void]$log.AppendLine(("另有 {0} 个带 (N) 后缀的产物文件夹在基线里没有对应 HTML（属手工时代的遗留目录，本工具不动它们）：" -f $orphan.Count))
foreach ($o in $orphan) { [void]$log.AppendLine("   - $o") }

Write-Host ''
Write-Host ("重复组 {0} | 待删项目 {1} | 可释放 {2} GB | 整组跳过 {3}" -f $kept, $victims.Count, [math]::Round($freedBytes/1GB,2), $skippedGroups) -ForegroundColor Cyan
if ($orphan.Count -gt 0) {
    Write-Host ("手工遗留的 (N) 文件夹 {0} 个（无基线 HTML，未处理）：" -f $orphan.Count) -ForegroundColor DarkGray
    foreach ($o in $orphan) { Write-Host ("     · {0}" -f $o) -ForegroundColor DarkGray }
}

# ---------- 4) 执行删除 ----------
if ($victims.Count -eq 0) {
    Write-Host '没有需要删除的重复项目。' -ForegroundColor Green
} elseif (-not $Apply) {
    Write-Host '以上仅为预览，未删除任何文件。确认无误后执行：.\tools\dedupe.ps1 -Apply' -ForegroundColor Yellow
} else {
    if ([System.IO.File]::Exists($Cfg.Manifest)) {
        Copy-Item -LiteralPath $Cfg.Manifest -Destination (Join-Path $Cfg.StateDir 'manifest.bak.csv') -Force
        Write-Host '  已备份 state\manifest.bak.csv' -ForegroundColor DarkGray
    }
    $victimNames = @($victims | ForEach-Object { $_.Name })
    $nDir = 0; $nHtml = 0
    $victimHash = @{}     # 被删项目“自己那份”HTML 的哈希（manifest 主行）
    $redirect = @{}       # 别名行重定向：victim -> keeper
    foreach ($v in $victims) {
        $d = Join-Path $Cfg.OutDir $v.Name
        if ([System.IO.Directory]::Exists($d)) { [System.IO.Directory]::Delete($d, $true); $nDir++ }
        if ([System.IO.File]::Exists($v.Html)) {
            $victimHash[(Get-ContentHash ([System.IO.File]::ReadAllBytes($v.Html)))] = $true
            [System.IO.File]::Delete($v.Html); $nHtml++
        }
        $redirect[$v.Name] = $v.Keep
        Write-Host ("  已删: {0}" -f $v.Name) -ForegroundColor Green
    }
    # manifest：只丢掉被删项目的主行；指向被删项目的别名行改指到保留方（不能一并删，否则下次又会被重判入库）
    # 注意判据必须是 hash + datedName 两个一起：上游字节完全相同的重复投稿下，
    # 保留方与被删方的 hash 一模一样，只按 hash 筛会把保留方的主行一起删掉
    $man = @(Import-Csv -LiteralPath $Cfg.Manifest)
    $fixed = @()
    foreach ($r in $man) {
        if ($redirect.ContainsKey($r.datedName) -and $victimHash.ContainsKey($r.hash)) { continue }   # 被删项目自己的主行
        if ($redirect.ContainsKey($r.datedName)) {
            $r | Add-Member -NotePropertyName datedName -NotePropertyValue $redirect[$r.datedName] -Force
        }
        $fixed += $r
    }
    $fixed | Export-Csv -LiteralPath $Cfg.Manifest -NoTypeInformation -Encoding UTF8
    # pending：把被删项目从待处理清单里摘掉
    if ([System.IO.File]::Exists($Cfg.PendingFile)) {
        $p = @([System.IO.File]::ReadAllLines($Cfg.PendingFile) | ForEach-Object { $_.Trim() } | Where-Object { $_ -and ($victimNames -notcontains $_) })
        [System.IO.File]::WriteAllLines($Cfg.PendingFile, $p, (New-Object System.Text.UTF8Encoding($true)))
    }
    Write-Host ("完成: 删产物文件夹 {0} 个 / 基线 HTML {1} 个 / manifest {2} -> {3} 行 / 释放 {4} GB" -f `
        $nDir, $nHtml, $man.Count, $fixed.Count, [math]::Round($freedBytes/1GB,2)) -ForegroundColor Green
    [void]$log.AppendLine(("【执行结果】删文件夹 {0} / HTML {1} / manifest {2}->{3} 行" -f $nDir, $nHtml, $man.Count, $fixed.Count))
}

$rep = Join-Path $Cfg.LogDir ("dedupe_{0}.txt" -f (Get-Date -Format 'yymmdd_HHmmss'))
[System.IO.File]::WriteAllText($rep, $log.ToString(), (New-Object System.Text.UTF8Encoding($true)))
Write-Host ("报告: {0}" -f $rep)
