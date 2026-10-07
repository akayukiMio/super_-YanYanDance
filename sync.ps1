<#
.SYNOPSIS
    【主入口】同步上游仓库 → 比对基线 → 新项目重命名入库 → 生成待处理清单 →（可选）直接下载。
.DESCRIPTION
    流程：
      1) repo\ 不存在则 git clone，存在则 git pull --ff-only（-NoPull 可跳过）
      2) 逐个计算仓库 HTML 的「整页哈希」与「画廊内容签名」，与 state\manifest.csv 两级比对：
         - 整页哈希已存在  → 同一份文件，跳过
         - 签名已存在        → 上游把同一画廊重复投稿成另一个 HTML 文件：只记别名，不重复入库、不重下
         - 两者都不存在      → 真新增：解析标题/日期 → 生成 [yy-mm-dd]标题 名 →
                              复制到 repo_html\ 基线 → 追加 manifest → 写入 pending.txt
      3) -Run 时调用 run_all.ps1 -ListFile pending.txt 只处理新增项目
    两级比对的作用：上游改文件名仍能识别（靠签名）；同一画廊重复投稿不会再下一遍（也靠签名）。
    上游修改已有项目：如果同标题同日期的 HTML 媒体内容（图片/视频 URL）有增减，会更新 manifest 条目并补下新增部分到原文件夹；
    如果只是改了文案/推广文字而媒体未变，视为别名跳过。
    重要：本脚本只看 pending，绝不回查/回补历史项目的产物，
         所以你手动删掉的产物文件夹不会被自动恢复（查看被删项：maint.ps1 -Action MissingOut）。
.PARAMETER DryRun
    只报告将发生什么，不写任何文件、不下载。
.PARAMETER NoPull
    不执行 git pull，直接用当前 repo\ 副本比对。
.PARAMETER Run
    比对结束后立即调用 run_all.ps1 下载新增项目。
.PARAMETER Force
    忽略 manifest，把仓库内全部 HTML 视为待处理重新入库（用于重建基线）。
.EXAMPLE
    .\sync.ps1 -DryRun                 # 看看上游有什么新东西
    .\sync.ps1                         # 入库新增项目，生成 pending.txt
    .\sync.ps1 -Run                    # 入库并立即下载
    .\sync.ps1 -Run -ImagesOnly -Quiet # 只下图片
#>
param(
    [switch]$DryRun,
    [switch]$NoPull,
    [switch]$Run,
    [switch]$Force,
    [switch]$Rebuild,
    [switch]$ImagesOnly,
    [switch]$VideosOnly,
    [switch]$Quiet
)

. (Join-Path $PSScriptRoot 'config.ps1')
Set-NetBaseline

function Write-Title($t) { Write-Host ''; Write-Host ('=' * 78) -ForegroundColor DarkCyan; Write-Host ("  " + $t) -ForegroundColor Cyan; Write-Host ('=' * 78) -ForegroundColor DarkCyan }

# 上游地址不在 config.ps1 里（它含来源信息），由 config.local.ps1 提供；-Rebuild 不访问仓库
if (-not $Rebuild -and -not $Cfg.RepoUrl) {
    Write-Host '  缺少上游仓库地址：请复制 config.local.example.ps1 为 config.local.ps1 并填 $Cfg["RepoUrl"]' -ForegroundColor Red
    return
}

# ---------- 0) 重建 manifest（以 repo_html 基线为准，不访问仓库）----------
if ($Rebuild) {
    Write-Title '重建 manifest（规范化哈希）'
    $rows = @()
    foreach ($f in ([System.IO.Directory]::GetFiles($Cfg.BaselineDir, '*.html') | Sort-Object)) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($f)
        $bytes = [System.IO.File]::ReadAllBytes($f)
        $g = Parse-Gallery ([System.Text.Encoding]::UTF8.GetString($bytes))
        $date = ''
        if ($name -match '^\[(\d{2}-\d{2}-\d{2})\]') { $date = $Matches[1] }
        $rows += [pscustomobject]@{
            hash = (Get-ContentHash $bytes); datedName = $name; date = $date
            imgExp = $g.Imgs.Count; vidExp = $g.Vids.Count
            firstSeen = (Get-Date -Format 'yyyy-MM-dd'); lastProcessed = (Get-Date -Format 'yyyy-MM-dd')
            gkey = (Get-GalleryKey ([System.Text.Encoding]::UTF8.GetString($bytes)))
        }
    }
    if ($DryRun) {
        Write-Host ("  [DryRun] 将重建 {0} 行 manifest" -f $rows.Count)
    } else {
        $rows | Export-Csv -LiteralPath $Cfg.Manifest -NoTypeInformation -Encoding UTF8
        Write-Host ("  已重建: {0} 行 -> {1}" -f $rows.Count, $Cfg.Manifest)
    }
    return
}

# ---------- 1) 仓库 ----------
Write-Title '步骤 1/4  同步上游仓库'
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if (-not $gitCmd) { Write-Host '  未找到 git，请先安装 git 或加入 PATH' -ForegroundColor Red; exit 1 }

if (-not [System.IO.Directory]::Exists((Join-Path $Cfg.RepoDir '.git'))) {
    if ($DryRun) { Write-Host ("  [DryRun] 将 clone {0} -> {1}" -f $Cfg.RepoUrl, $Cfg.RepoDir) }
    else {
        Write-Host ("  clone {0}" -f $Cfg.RepoUrl)
        # core.autocrlf=false：保持仓库字节原貌，避免 CRLF 转换干扰内容比对
        & git clone --quiet -c core.autocrlf=false $Cfg.RepoUrl $Cfg.RepoDir
        if ($LASTEXITCODE -ne 0) { Write-Host '  clone 失败' -ForegroundColor Red; exit 1 }
    }
} elseif (-not $NoPull) {
    if ($DryRun) { Write-Host '  [DryRun] 将执行 git pull --ff-only' }
    else {
        Write-Host '  git pull --ff-only ...'
        & git -C $Cfg.RepoDir pull --ff-only 2>&1 | ForEach-Object { Write-Host ("    " + $_) }
    }
} else {
    Write-Host '  跳过 pull（-NoPull）'
}
if ([System.IO.Directory]::Exists((Join-Path $Cfg.RepoDir '.git'))) {
    if (-not $DryRun) { & git -C $Cfg.RepoDir config core.autocrlf false 2>&1 | Out-Null }
    $last = (& git -C $Cfg.RepoDir log -1 --format='%h  %ad  %s' --date=short) 2>&1
    Write-Host ("  最新提交: {0}" -f $last)
}

# ---------- 2) 载入 manifest（并保证每行都有画廊签名）----------
$manifest = @()
if ([System.IO.File]::Exists($Cfg.Manifest)) { $manifest = @(Import-Csv -LiteralPath $Cfg.Manifest) }
$byHash = @{}; $byName = @{}; $byKey = @{}
$manifestDirty = $false   # true = 老格式无 gkey 列，本轮补齐后需回写
foreach ($r in @($manifest)) {
    if (-not $r.PSObject.Properties['gkey'] -or [string]::IsNullOrEmpty([string]$r.gkey)) {
        $hf = Join-Path $Cfg.BaselineDir ($r.datedName + '.html')
        $k = ''
        if ([System.IO.File]::Exists($hf)) { $k = Get-GalleryKeyByFile $hf }
        $r | Add-Member -NotePropertyName gkey -NotePropertyValue $k -Force
        $manifestDirty = $true
    }
    $byHash[$r.hash] = $r
    $byName[$r.datedName] = $r
    if ($r.gkey -and -not $byKey.ContainsKey($r.gkey)) { $byKey[$r.gkey] = $r }
}
if ($Force) {
    # 全量重建入库：三个索引都得清空，否则旧记录会把全部文件判成“已知”
    $byHash = @{}; $byKey = @{}; $byName = @{}
}

# ---------- 3) 比对 ----------
Write-Title '步骤 2/4  整页哈希 + 画廊签名 两级比对'
$repoFiles = @([System.IO.Directory]::GetFiles($Cfg.RepoDir, '*.html'))
$today = Get-Date -Format 'yyyy-MM-dd'

$new = @(); $updated = @(); $known = 0; $skippedTool = 0
$newRows = @(); $aliasRows = @(); $dupAlias = @()
$updateRows = @(); $updateNames = @()   # 上游修改已有项目（媒体有增删）

foreach ($f in $repoFiles) {
    $rawName = [System.IO.Path]::GetFileName($f)
    if ($Cfg.ExcludeHtml -contains $rawName) { $skippedTool++; continue }
    $isTool = $false
    foreach ($w in $Cfg.ExcludeHtmlWildcard) { if ($rawName -like $w) { $isTool = $true } }
    if ($isTool) { $skippedTool++; continue }

    $bytes = [System.IO.File]::ReadAllBytes($f)
    $hash = Get-ContentHash $bytes   # 规范化后哈希（抵御 CRLF/BOM 差异）
    if ($byHash.ContainsKey($hash)) { $known++; continue }

    $txt = [System.Text.Encoding]::UTF8.GetString($bytes)
    $key = Get-GalleryKey $txt       # 画廊内容签名（标题+日期+图片URL序列+视频URL序列）

    # 同一画廊的重复投稿（上游换文件名 / 页面有无关字节差异）：记别名，绝不重下
    # （这条分支就是“已落库项目又被完整重下到 xxx(2) 文件夹”的根因修复点）
    if ($byKey.ContainsKey($key)) {
        $canon = $byKey[$key]
        $ar = [pscustomobject]@{
            hash = $hash; datedName = $canon.datedName; date = $canon.date
            imgExp = $canon.imgExp; vidExp = $canon.vidExp
            firstSeen = $today; lastProcessed = $canon.lastProcessed; gkey = $key
        }
        $aliasRows += $ar; $byHash[$hash] = $ar
        $dupAlias += ("{0}  与已入库项目同一画廊 -> {1}" -f $rawName, $canon.datedName)
        continue
    }

    $g = Parse-Gallery $txt
    $name = Make-SafeName $g.Title $g.Date
    # 同名项目已入库：判断是上游修改了媒体内容，还是仅仅改了文案
    if ($byName.ContainsKey($name)) {
        $existing = $byName[$name]
        # 重新解析旧基线 HTML 取旧媒体 URL
        $oldHtml = Join-Path $Cfg.BaselineDir ($name + '.html')
        $oldImgs = @(); $oldVids = @()
        if ([System.IO.File]::Exists($oldHtml)) {
            $oldTxt = [System.IO.File]::ReadAllText($oldHtml, [System.Text.Encoding]::UTF8)
            $oldG = Parse-Gallery $oldTxt
            $oldImgs = $oldG.Imgs; $oldVids = $oldG.Vids
        }
        $newImgs = $g.Imgs; $newVids = $g.Vids
        # 比较媒体 URL 集合：只看增减，不看顺序
        $oldImgSet = @($oldImgs | Sort-Object -Unique)
        $newImgSet = @($newImgs | Sort-Object -Unique)
        $oldVidSet = @($oldVids | Sort-Object -Unique)
        $newVidSet = @($newVids | Sort-Object -Unique)
        $imgAdded = $newImgSet | Where-Object { $oldImgSet -notcontains $_ }
        $imgRemoved = $oldImgSet | Where-Object { $newImgSet -notcontains $_ }
        $vidAdded = $newVidSet | Where-Object { $oldVidSet -notcontains $_ }
        $vidRemoved = $oldVidSet | Where-Object { $newVidSet -notcontains $_ }
        $mediaChanged = (@($imgAdded).Count + @($imgRemoved).Count + @($vidAdded).Count + @($vidRemoved).Count) -gt 0

        if (-not $mediaChanged) {
            # 仅文案/元数据变更，gkey 不变：视为别名，跳过不重下
            $ar = [pscustomobject]@{
                hash = $hash; datedName = $existing.datedName; date = $existing.date
                imgExp = $existing.imgExp; vidExp = $existing.vidExp
                firstSeen = $existing.firstSeen; lastProcessed = $existing.lastProcessed; gkey = $existing.gkey
            }
            $aliasRows += $ar; $byHash[$hash] = $ar
            $dupAlias += ("{0}  与已入库项目同一画廊 -> {1}（仅文案变更）" -f $rawName, $existing.datedName)
            continue
        }
        # 媒体有增减：更新已有 manifest 条目，补下新增部分到原文件夹
        $existing.hash = $hash
        $existing.imgExp = [string]$newImgs.Count
        $existing.vidExp = [string]$newVids.Count
        $existing.gkey = $key
        # 更新基线 HTML（让 run_all 解析到新的 URL 列表）
        if (-not $DryRun) {
            [System.IO.File]::Copy($f, (Join-Path $Cfg.BaselineDir ($name + '.html')), $true)
        }
        $updateRows += $existing
        $updateNames += $name
        $dImg = @($imgAdded).Count; $dVid = @($vidAdded).Count
        $rImg = @($imgRemoved).Count; $rVid = @($vidRemoved).Count
        $updated += ("{0}  (图 {1}->{2}, 视 {3}->{4})  <- {5}" -f $name, $oldImgs.Count, $newImgs.Count, $oldVids.Count, $newVids.Count, $rawName)
        continue
    }

    $row = [pscustomobject]@{
        hash = $hash; datedName = $name; date = $g.Date
        imgExp = $g.Imgs.Count; vidExp = $g.Vids.Count
        firstSeen = $today; lastProcessed = ''
        gkey = $key
    }
    $newRows += $row
    # 三个索引都当场回填，否则同一轮里出现两份相同画廊时不会被识别为重复
    $byName[$name] = $row; $byHash[$hash] = $row; $byKey[$key] = $row
    $new += ("{0}  (图{1}/视{2})  <- 原文件 {3}" -f $name, $g.Imgs.Count, $g.Vids.Count, $rawName)

    if (-not $DryRun) {
        [System.IO.File]::Copy($f, (Join-Path $Cfg.BaselineDir ($name + '.html')), $true)
    }
}

Write-Host ("  仓库 HTML : {0} 个（工具页 {1} 个已排除）" -f $repoFiles.Count, $skippedTool)
Write-Host ("  已处理过  : {0}" -f $known) -ForegroundColor DarkGray
Write-Host ("  重复投稿/文案变更: {0} 个（同一画廊换文件名/微异重复，已跳过不重下）" -f $dupAlias.Count) -ForegroundColor Magenta
foreach ($x in $dupAlias) { Write-Host ("     = {0}" -f $x) }
Write-Host ("  新增项目  : {0}" -f $new.Count) -ForegroundColor Green
foreach ($x in $new) { Write-Host ("     + {0}" -f $x) }
Write-Host ("  上游修改已有项目: {0}（媒体有增减，将补下新增部分到原文件夹）" -f $updated.Count) -ForegroundColor Yellow
foreach ($x in $updated) { Write-Host ("     ~ {0}" -f $x) }

# ---------- 4) 落盘 ----------
Write-Title '步骤 3/4  写入基线与待处理清单'
$changed = ($new.Count + $updated.Count + $aliasRows.Count)
$hasWork = ($newRows.Count + $updateNames.Count)
if ($DryRun) {
    if ($changed -gt 0) { Write-Host ("  [DryRun] 将新增 {0} 行 manifest（其中 {1} 行为重复别名），更新 {2} 行已有项目，并写入 {3} 条 pending" -f $changed, $aliasRows.Count, $updateNames.Count, ($newRows.Count + $updateNames.Count)) }
    else { Write-Host '  [DryRun] 无变化' }
    if ($manifestDirty) { Write-Host '  [DryRun] 将为 manifest 补齐 gkey 列' }
} elseif ($changed -eq 0 -and -not $manifestDirty) {
    Write-Host '  无变化：manifest / pending.txt 保持不变'
} else {
    $all = @()
    if (-not $Force) { $all = $manifest }
    else { Write-Host '  -Force: manifest 仅保留本次入库结果' -ForegroundColor Yellow }
    $all = @($all) + @($newRows) + @($aliasRows)
    $all | Export-Csv -LiteralPath $Cfg.Manifest -NoTypeInformation -Encoding UTF8
    Write-Host ("  manifest : {0} 行 -> {1}" -f $all.Count, $Cfg.Manifest) -ForegroundColor $(if ($manifestDirty) { 'Cyan' } else { 'DarkGray' })
    if ($hasWork -gt 0) {
        # 与上一轮遗留的 pending 合并而不是直接覆盖：否则上次没下完的项目会被抹掉
        $prev = @()
        if ([System.IO.File]::Exists($Cfg.PendingFile)) {
            $prev = @([System.IO.File]::ReadAllLines($Cfg.PendingFile) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        $pendingNames = @((@($prev) + @($newRows | ForEach-Object { $_.datedName }) + @($updateNames)) | Select-Object -Unique)
        [System.IO.File]::WriteAllLines($Cfg.PendingFile, $pendingNames, (New-Object System.Text.UTF8Encoding($true)))
        Write-Host ("  pending  : {0} 条（本次新增 {1}，上游修改 {2}）-> {3}" -f $pendingNames.Count, $newRows.Count, $updateNames.Count, $Cfg.PendingFile)
        $tImg = ($newRows | Measure-Object -Property imgExp -Sum).Sum
        $tVid = ($newRows | Measure-Object -Property vidExp -Sum).Sum
        if ($tImg -eq $null) { $tImg = 0 }; if ($tVid -eq $null) { $tVid = 0 }
        # 修改项目的工作量只能从基线 HTML 差异估算，这里只报新增项目的
        if ($tImg -gt 0 -or $tVid -gt 0) {
            Write-Host ("  预计工作量: 图片 {0} 张 / 视频 {1} 个（不含修改项目的增量）" -f $tImg, $tVid) -ForegroundColor Cyan
        }
        if ($updateNames.Count -gt 0) {
            foreach ($un in $updateNames) { Write-Host ("     ~ {0}（补下新增媒体）" -f $un) -ForegroundColor Yellow }
        }
    } else {
        Write-Host '  本轮无新项目也无修改项目，pending 保持不变' -ForegroundColor DarkGray
    }
}

# ---------- 5) 可选：直接下载 ----------
Write-Title '步骤 4/4  下载新增项目'
if (-not $Run) {
    Write-Host '  未指定 -Run，跳过下载。手动执行：'
    Write-Host ("     .\run_all.ps1 -ListFile `"{0}`"" -f $Cfg.PendingFile)
} elseif ($DryRun) {
    Write-Host '  [DryRun] 将调用 run_all.ps1 处理 pending 清单'
} else {
    # 以 pending 是否为空为准（而非本次新增数），这样中断后重跑 sync -Run 能直接续传
    $pend = @()
    if ([System.IO.File]::Exists($Cfg.PendingFile)) {
        $pend = @([System.IO.File]::ReadAllLines($Cfg.PendingFile) | Where-Object { $_.Trim() })
    }
    if ($pend.Count -eq 0) {
        Write-Host '  pending 为空，无需下载'
    } else {
        # 必须用哈希表 splatting（按参数名绑定）；数组 splatting 是按位置传参，会把开关错位
        $runArgs = @{ ListFile = $Cfg.PendingFile }
        if ($ImagesOnly) { $runArgs['ImagesOnly'] = $true }
        if ($VideosOnly) { $runArgs['VideosOnly'] = $true }
        if ($Quiet) { $runArgs['Quiet'] = $true }
        Write-Host ("  调用 run_all.ps1（pending {0} 条）..." -f $pend.Count) -ForegroundColor Cyan
        & (Join-Path $PSScriptRoot 'run_all.ps1') @runArgs

        # 回收 pending：只保留仍不齐全的项，使 sync -Run 可反复执行、幂等续跑
        $manByName = @{}
        foreach ($r in (Import-Csv -LiteralPath $Cfg.Manifest)) { $manByName[$r.datedName] = $r }
        $imgExts = @('.jpg','.jpeg','.png','.gif','.webp')
        $still = @()
        foreach ($nm in $pend) {
            $nmt = $nm.Trim()
            if (-not $nmt) { continue }
            $d = Join-Path $Cfg.OutDir $nmt
            if (-not [System.IO.Directory]::Exists($d)) { $still += $nmt; continue }
            $ni = 0; $nv = 0
            foreach ($f in [System.IO.Directory]::GetFiles($d)) {
                $e = [System.IO.Path]::GetExtension($f).ToLower()
                if ($imgExts -contains $e) { $ni++ } elseif ($e -eq '.mp4') { $nv++ }
            }
            $ei = 0; $ev = 0
            if ($manByName.ContainsKey($nmt)) { $ei = [int]$manByName[$nmt].imgExp; $ev = [int]$manByName[$nmt].vidExp }
            if ($ni -lt $ei -or $nv -lt $ev) { $still += $nmt }
        }
        [System.IO.File]::WriteAllLines($Cfg.PendingFile, $still, (New-Object System.Text.UTF8Encoding($true)))
        Write-Host ("  pending 回收: 已齐全 {0} 项移出，剩余 {1} 项待重试" -f ($pend.Count - $still.Count), $still.Count) -ForegroundColor Cyan
        foreach ($s in $still) { Write-Host ("     ! {0}" -f $s) -ForegroundColor Yellow }
    }
}
