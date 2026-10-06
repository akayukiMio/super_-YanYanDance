<#
.SYNOPSIS
    画廊搬运一体化下载器：图片 + 视频 一次跑完，并输出汇总报表。
.DESCRIPTION
    提取每个 HTML 的正片图片(img-container/裸img)与 HLS 视频(m3u8)，下载到
    <OutDir>\<[yy-mm-dd]标题>\ 下（图片 0001.jpg…，视频 video_01.mp4…）。
    路径与默认并发均取自 config.ps1；断点续传基于磁盘文件状态（图片验魔数、视频看 mp4）。
    图片走全局并发池；视频走“每视频一个子进程 + 进程内串行”（源站对并发极敏感）。
.PARAMETER ListFile
    只处理清单文件中列出的项目（每行一个基线名，可不含 .html）；sync.ps1 生成 pending.txt 后使用。
.PARAMETER Year
    只处理日期前缀为该两位年份的文件，如 "25"。留空=全部年份。
.PARAMETER ImagesOnly / VideosOnly
    只跑图片或只跑视频。默认两者都跑。
.PARAMETER ListOnly
    只统计每个项目的图片/视频数量，不下载。
.PARAMETER NoProgress
    不写 Write-Progress 进度条。stdout 被重定向时（Web 层用管道采集日志）会自动开启，
    因为进度条的转义序列会混进日志流。
.EXAMPLE
    .\run_all.ps1 -ListFile .\state\pending.txt          # 只跑新增项目（推荐）
    .\run_all.ps1 -Year 26 -Month 08 -ImagesOnly -Quiet  # 按月份补图片
    .\run_all.ps1 -Year 25 -ListOnly                     # 只统计不下载
#>
param(
    [string]$Year = '',
    [string]$Month = '',
    [string]$ListFile = '',
    [switch]$ImagesOnly,
    [switch]$VideosOnly,
    [switch]$ListOnly,
    [switch]$ToMp4,
    [switch]$ConvertOnly,
    [switch]$Ascii,
    [switch]$Quiet,
    [switch]$NoProgress,
    [int]$Shard = 0,
    [int]$ShardOf = 0,
    [int]$Degree = 0,
    [int]$SegDegree = 0
)

# 路径/黑名单/默认并发全部来自 config.ps1（唯一真值源，项目可整体搬迁）
. (Join-Path $PSScriptRoot 'config.ps1')
Set-NetBaseline
if ($Degree -le 0) { $Degree = $Cfg.Degree }
if ($SegDegree -le 0) { $SegDegree = $Cfg.SegDegree }
# 输出被重定向（无真实控制台）时，进度条转义序列会污染采集到的日志 -> 自动关闭
if (-not $NoProgress -and [Console]::IsOutputRedirected) { $NoProgress = $true }

$Dir  = $Cfg.BaselineDir   # HTML 来源：基线目录 repo_html
$Root = $Cfg.OutDir        # 产物根目录：每个项目一个同名文件夹

# 始终写一份干净 UTF-8 日志；-Ascii 模式下控制台只输出半角字符（避免某些终端全角字渲染重复）
# 用常驻 StreamWriter 缓冲写入：逐行 AppendAllText 会每行开关一次文件+新建编码对象，
# 上万张图时是可观的主线程开销
$script:LogPath = Join-Path $Cfg.LogDir 'run_all_latest.log'
$script:LogWriter = New-Object System.IO.StreamWriter($script:LogPath, $false, (New-Object System.Text.UTF8Encoding($true)))
$script:LogWriter.AutoFlush = $false
$script:LogLines = 0
function script:Close-Log { if ($script:LogWriter) { $script:LogWriter.Flush(); $script:LogWriter.Dispose(); $script:LogWriter = $null } }
function script:Write-Host {
    param(
        [Parameter(Position=0, ValueFromRemainingArguments=$true)]$Object,
        $ForegroundColor,
        [switch]$NoNewline,
        $Separator = ' '
    )
    $line = ($Object -join $Separator)
    $script:LogWriter.WriteLine($line)
    $script:LogLines++
    if (($script:LogLines % 200) -eq 0) { $script:LogWriter.Flush() }
    $show = if ($Ascii) { ($line -replace '[^\x00-\x7F]', '') } else { $line }
    if ($ForegroundColor) { Microsoft.PowerShell.Utility\Write-Host $show -ForegroundColor $ForegroundColor -NoNewline:$NoNewline }
    else { Microsoft.PowerShell.Utility\Write-Host $show -NoNewline:$NoNewline }
}

$reImgContainer = [regex]'<div class="img-container">[\s\S]*?<img\s+src="([^"]+)"'
$reBareImg      = [regex]'<img[^>]+src="([^"]+)"'
$reM3u8         = [regex]'https?://[^"''<>\s]+?\.m3u8'

# 黑名单：永远不下载这些 m3u8（共享宣传视频等），维护在 config.ps1
$BlockM3u8 = $Cfg.BlockM3u8

function Write-Banner($text) {
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor DarkCyan
    Write-Host ("  " + $text) -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor DarkCyan
}
function Write-FileHeader($folder, $imgN, $vidN) {
    Write-Host ""
    Write-Host ("-- " + $folder) -ForegroundColor Yellow
    Write-Host ("   图片 {0} 张 | 视频 {1} 个" -f $imgN, $vidN) -ForegroundColor DarkYellow
}
function Folder-Of($baseName) {
    # 产物文件夹与 HTML 源文件同名：保留 [yy-mm-dd] 日期前缀（便于按时间统计/归档）
    return $baseName -replace '[\\/:*?"<>|]', '_'
}
# 图片完整性：非空 且 魔数与扩展名匹配（拦截中断留下的截断文件）
function Test-ImageOk($path) {
    if (-not [System.IO.File]::Exists($path)) { return $false }
    $fi = Get-Item -LiteralPath $path
    if ($fi.Length -le 0) { return $false }
    $fs = $fi.OpenRead(); $b = New-Object byte[] 4; $fs.Read($b,0,4) | Out-Null; $fs.Close()
    $hex = ($b | ForEach-Object { $_.ToString('X2') }) -join ''
    switch -Regex ($fi.Extension) {
        '\.jpg|\.jpeg' { return $hex.StartsWith('FFD8FF') }
        '\.png'        { return $hex -eq '89504E47' }
        '\.gif'        { return $hex.StartsWith('47494638') }
        '\.webp'       { return $hex -eq '52494646' }
        default        { return $true }
    }
}
# 视频完整性：非空 且 总长度是 MPEG-TS 包(188B)的整数倍（截断的必然不整除）
function Test-VideoOk($path) {
    if (-not [System.IO.File]::Exists($path)) { return $false }
    $len = (Get-Item -LiteralPath $path).Length
    return ($len -gt 0 -and ($len % 188) -eq 0)
}
# 把完整 .ts 无损 remux 为 .mp4（需 ffmpeg）；ts 仅作中间件，转完即删
function Convert-Videos {
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        Write-Host "未检测到 ffmpeg，跳过 MP4 转换" -ForegroundColor Yellow
        return
    }
    $n = 0
    foreach ($d in Get-ChildItem -LiteralPath $Root -Directory) {
        foreach ($ts in Get-ChildItem -LiteralPath $d.FullName -File -Filter '*.ts') {
            if (-not (Test-VideoOk $ts.FullName)) { continue }
            $mp4 = [System.IO.Path]::ChangeExtension($ts.FullName, '.mp4')
            if ([System.IO.File]::Exists($mp4)) { continue }
            Write-Host ("   [mp4] {0} -> {1}" -f $ts.Name, (Split-Path $mp4 -Leaf)) -ForegroundColor Cyan
            & ffmpeg -hide_banner -loglevel error -y -i $ts.FullName -c copy $mp4
            if ($LASTEXITCODE -eq 0 -and [System.IO.File]::Exists($mp4)) {
                $n++
                Remove-Item -LiteralPath $ts.FullName -Force
                Write-Host "        ok (ts 已删除)" -ForegroundColor Green
            } else {
                Write-Host "        ffmpeg 转换失败" -ForegroundColor Red
            }
        }
    }
    Write-Host ("MP4 转换完成: {0} 个" -f $n) -ForegroundColor Cyan
}

# ---------- 高速并发下载：HttpClient + Parallel，替代单线程 Invoke-WebRequest ----------
Add-Type -AssemblyName System.Net.Http
$script:Degree = $Degree
$script:Http = New-Object System.Net.Http.HttpClient
$script:Http.Timeout = [TimeSpan]::FromSeconds(180)

function Invoke-FastDownload {
    param([object[]]$Items, [int]$Degree = 16, [string]$Kind = 'img')
    # RunspacePool 并发；worker 内 WebClient + 自动重试3次；完成一个立即打印一个（可视化）
    $pool = [runspacefactory]::CreateRunspacePool(1, $Degree)
    $pool.Open()
    $sb = {
        param($Url, $Out, $Base)
        $e = @{ Url=$Url; Out=''; Ok=$false; Bytes=0; Err='' }
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            try {
                # 随机抖动平滑请求速率，降低触发源站静默丢包阈值的概率
                Start-Sleep -Milliseconds (Get-Random -Maximum 300)
                # 异步 BeginGetResponse + WaitOne 硬超时 + Abort：
                # 同步 GetResponse 在 DNS/accept 挂起点不受 Timeout 约束，会永久占住 runspace 导致池子饿死
                $req = [System.Net.HttpWebRequest]::Create($Url)
                $req.Timeout = 60000
                $req.ReadWriteTimeout = 60000
                # 连接复用：减少新建 TCP/TLS 连接突发
                # 注：不要访问 $req.ServicePoint —— 该属性 getter 会同步做 DNS 解析，
                # DNS 被黑洞时会永久挂起且不受 Timeout/WaitOne 约束（曾导致窗口被占满、进度卡死）
                $req.KeepAlive = $true
                $req.UserAgent = 'Mozilla/5.0'
                $ar = $req.BeginGetResponse($null, $null)
                if (-not $ar.AsyncWaitHandle.WaitOne(60000)) {
                    $req.Abort()
                    throw [System.TimeoutException]::new('connect/response timeout 60s')
                }
                $resp = $req.EndGetResponse($ar)
                try {
                    $ct = "$($resp.ContentType)"
                    $st = $resp.GetResponseStream()
                    $ms = New-Object System.IO.MemoryStream
                    $st.CopyTo($ms)
                    $b = $ms.ToArray()
                } finally { $resp.Close() }
                $outPath = $Out
                if (-not $outPath) {
                    $ext = '.jpg'; if ($ct -match 'png'){$ext='.png'} elseif ($ct -match 'webp'){$ext='.webp'} elseif ($ct -match 'gif'){$ext='.gif'}
                    $outPath = $Base + $ext
                }
                [System.IO.File]::WriteAllBytes($outPath, $b)
                $e.Out=$outPath; $e.Ok=$true; $e.Bytes=$b.Length; $e.Err=''
                break
            } catch {
                $e.Err = $_.Exception.Message
                # 退避重试：2s
                if ($attempt -lt 2) { Start-Sleep -Milliseconds 2000 }
            }
        }
        return $e
    }
    $total = $Items.Count
    $results = New-Object 'System.Collections.Generic.List[object]'
    $jobs = New-Object 'System.Collections.Generic.List[object]'
    $next = 0
    $active = 0
    $done = 0
    $lastGrow = 0
    # 滑动窗口 + 爬坡：初始只开 4 条连接，每完成 4 个任务窗口 +2，
    # 且“完成一个才放入一个”，避免新建连接突发触发源站静默丢包
    # 轮转交错下，窗口≈活跃主机数 → 每主机仅~1条连接（可靠区），聚合速率高
    $window = [math]::Min(8, $total)
    $lastBeat = [DateTime]::Now
    $lastDoneChange = [DateTime]::Now
    $pauseUntil = [DateTime]::Now
    $lastLaunch = [DateTime]::Now
    $okCount = 0
    # 自适应速率：发起间隔 paceMs 与窗口 window 根据成功/冷却动态调整，
    # 收敛到源站容忍的最大速率（串行可靠但慢 ↔ 高并发触发冷却）
    $paceMs = 800
    $paceFloor = 200
    $okSinceCd = 0
    if ($Kind -eq 'img') {
        # 图片主机实测可承受高并发，不需要为视频主机设计的“发起节拍”限速：
        # paceMs 地板 200ms 会把图片吞吐硬限在 5 张/秒（1 万张 ≈ 36 分钟），故图片直接满窗零间隔
        $window = [math]::Min($Degree, $total)
        $paceMs = 0
        $paceFloor = 0   # 否则爬坡里的 Max(200, ...) 会把间隔又抬回 200ms
    }
    while ($done -lt $total) {
        # 发起节拍：按 paceMs 间隔发起新请求，压低持续请求速率避免触发源站冷却
        while ($next -lt $total -and $active -lt $window -and [DateTime]::Now -ge $pauseUntil -and ([DateTime]::Now - $lastLaunch).TotalMilliseconds -ge $paceMs) {
            $it = $Items[$next]
            $ps = [powershell]::Create().AddScript($sb).AddArgument($it.Url).AddArgument($it.Out).AddArgument($it.Base)
            $ps.RunspacePool = $pool
            $jobs.Add([psobject]@{ Ps=$ps; Ar=$ps.BeginInvoke(); Url=$it.Url; Idx=$it.Idx; Key=$it.Key; SegTotal=$it.SegTotal })
            $next++; $active++
            $lastLaunch = [DateTime]::Now
        }
        $finished = New-Object 'System.Collections.Generic.List[object]'
        foreach ($j in $jobs) {
            if ($j.Ar.IsCompleted) {
                $finished.Add($j)
                $done++; $active--
                $lastDoneChange = [DateTime]::Now
                $e = $null
                try { $e = ($j.Ps.EndInvoke($j.Ar) | Select-Object -First 1) }
                catch { $e = @{ Url=$j.Url; Out=''; Ok=$false; Bytes=0; Err=$_.Exception.Message } }
                if (-not $e) { $e = @{ Url=$j.Url; Out=''; Ok=$false; Bytes=0; Err='no result' } }
                $results.Add($e)
                if ($e.Ok) {
                    $okCount++; $okSinceCd++
                    # 连续 8 个成功无冷却 → 提速：窗口 +1 且间隔 -100ms
                    if ($okSinceCd -ge 8) {
                        $okSinceCd = 0
                        if ($window -lt $Degree) { $window++ }
                        $paceMs = [math]::Max($paceFloor, $paceMs - 100)
                    }
                }
                if ($Kind -eq 'seg') {
                    if ($e.Ok) { Write-Host ("   [{0}] seg {1,2}/{2} ok   {3,5} KB" -f $j.Key, $j.Idx, $j.SegTotal, [math]::Round($e.Bytes/1KB)) -ForegroundColor DarkGreen }
                    else { Write-Host ("   [{0}] seg {1,2}/{2} FAIL {3}" -f $j.Key, $j.Idx, $j.SegTotal, $e.Err) -ForegroundColor Red }
                } else {
                    if ($e.Ok) { if (-not $Quiet) { Write-Host ("   [img {0,3}/{1}] OK    {2}  {3,5} KB" -f $j.Idx, $total, (Split-Path $e.Out -Leaf), [math]::Round($e.Bytes/1KB)) -ForegroundColor Green } }
                    else { Write-Host ("   [img {0,3}/{1}] FAIL  {2}" -f $j.Idx, $total, $e.Err) -ForegroundColor Red }
                }
                $j.Ps.Dispose()
            }
        }
        # 已完成的作业从列表移除：避免每轮重复遍历已完成项（大池下是 O(n²) 开销）
        foreach ($j in $finished) { [void]$jobs.Remove($j) }
        if ($done -gt 0 -and ($done - $lastGrow) -ge 4 -and $window -lt $Degree) {
            $window = [math]::Min($Degree, $window + 1)
            $lastGrow = $done
        }
        if ($done -lt $total) {
            Start-Sleep -Milliseconds 150
            # 心跳：每 10 秒至少打印一行，避免源站限速挂起时看起来像卡死
            if (([DateTime]::Now - $lastBeat).TotalSeconds -ge 10) {
                $lastBeat = [DateTime]::Now
                # 冷却检测：100s 零进展 → 暂停发起 20s + 间隔翻倍；
                # 不降窗：轮转下降窗会减少主机多样性，反而让毒主机垄断窗口
                if (([DateTime]::Now - $lastDoneChange).TotalSeconds -ge 100) {
                    $paceMs = [math]::Min(5000, [math]::Max($paceMs * 2, $paceFloor))
                    $okSinceCd = 0
                    $pauseUntil = [DateTime]::Now.AddSeconds(20)
                    $lastDoneChange = [DateTime]::Now
                    Write-Host ("   .. 源站冷却检测: 100s 无进展 -> 间隔 {0}ms, 退避 20s (窗口保持 {1})" -f $paceMs, $window) -ForegroundColor Yellow
                }
                Write-Host ("   .. 进行中 {0}/{1}  (在途 {2}, 窗口 {3}, 间隔 {4}ms)" -f $done, $total, $active, $window, $paceMs) -ForegroundColor DarkCyan
            }
        }
    }
    $pool.Close(); $pool.Dispose()
    return $results
}

# ---------- 收集目标文件 ----------
$files = Get-ChildItem -LiteralPath $Dir -Filter '*.html' | Where-Object {
    $n = $_.Name
    if ($Cfg.ExcludeHtml -contains $n) { return $false }
    foreach ($w in $Cfg.ExcludeHtmlWildcard) { if ($n -like $w) { return $false } }
    return $true
}
# 清单模式：只跑 pending.txt 里列出的项目（sync.ps1 生成）
if ($ListFile) {
    if (-not [System.IO.File]::Exists($ListFile)) { Write-Host ("清单文件不存在: {0}" -f $ListFile) -ForegroundColor Red; exit 1 }
    $want = @{}
    foreach ($ln in [System.IO.File]::ReadAllLines($ListFile)) {
        $t = $ln.Trim()
        if ($t) { $want[($t -replace '\.html$','')] = $true }
    }
    $files = $files | Where-Object { $want.ContainsKey($_.BaseName) }
    Write-Host ("清单模式: {0} 条待处理 -> 命中 {1} 个 HTML" -f $want.Count, @($files).Count)
}
# 按 [yy- 或 [yy-mm- 前缀过滤
$prefix = ''
if ($Year -and $Month) { $prefix = "[$Year-$Month-" }
elseif ($Year) { $prefix = "[$Year-" }
if ($prefix) { $files = $files | Where-Object { $_.BaseName.StartsWith($prefix) } }
$files = @($files)
# 分片：同一批次可拆到多个窗口并行跑（续传按磁盘文件判据，互不冲突）
if ($ShardOf -gt 1 -and $Shard -ge 1 -and $Shard -le $ShardOf) {
    $files = @($files | Where-Object { ([Math]::Abs($_.BaseName.GetHashCode()) % $ShardOf) -eq ($Shard - 1) })
    Write-Host ("分片: 第 {0}/{1} 片 -> {2} 个文件" -f $Shard, $ShardOf, $files.Count)
}

$scope = if ($prefix) { $prefix.TrimStart('[') + '*' } else { '全部' }
Write-Banner ("一体化下载器   范围: " + $scope + "   模式: " + $(if ($ListOnly) { '仅统计' } elseif ($ImagesOnly) { '仅图片' } elseif ($VideosOnly) { '仅视频' } else { '图片+视频' }))
Write-Host ("匹配内容文件: {0} 个" -f $files.Count)

if (-not [System.IO.Directory]::Exists($Root)) { [System.IO.Directory]::CreateDirectory($Root) | Out-Null }

# 仅转换模式：不下载，直接把已有 .ts 转 mp4
if ($ConvertOnly) {
    Convert-Videos
    Close-Log
    exit
}

# ---------- 统计/下载 ----------
$stat = [ordered]@{}   # folder -> @{imgExp;imgGot;vidExp;vidGot;mb;fails[List]}
$gImgOK=0; $gImgSkip=0; $gImgFail=0; $gVidOK=0; $gVidSkip=0; $gVidFail=0; $gSeg=0
$fi = 0; $totalFiles = $files.Count
$script:ImgItems = @()        # 全局图片池（跳项目攒批，避免小批次尾部浪费并发窗口）
$script:ImgKeyByUrl = @{}     # url -> 所属项目文件夹（失败清单归属用）
$script:SegItems = @()
$script:SegPerVideo = @()
$script:VideoMetas = @()

foreach ($f in $files) {
    $txt    = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    $folder = Folder-Of $f.BaseName
    $subDir = Join-Path $Root $folder
    $fi++
    $pf = if ($Ascii) { ($folder -replace '[^\x00-\x7F]', '') } else { $folder }
    if (-not $NoProgress) { Write-Progress -Id 1 -Activity 'Overall' -Status ("project {0}/{1}  {2}" -f $fi, $totalFiles, $pf) -PercentComplete ([int](($fi-1)*100/[math]::Max(1,$totalFiles))) }

    $imgUrls = @($reImgContainer.Matches($txt) | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    if ($imgUrls.Count -eq 0) { $imgUrls = @($reBareImg.Matches($txt) | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) }
    $vidUrls = @($reM3u8.Matches($txt) | ForEach-Object { $_.Value } | Select-Object -Unique)
    $vidUrls = @($vidUrls | Where-Object { $BlockM3u8 -notcontains $_ })

    if (-not $stat.Contains($folder)) {
        $stat[$folder] = @{ imgExp=0; imgGot=0; vidExp=0; vidGot=0; mb=0.0; fails=@() }
    }
    $stat[$folder].imgExp = $imgUrls.Count
    $stat[$folder].vidExp = $vidUrls.Count

    if ($ListOnly) { continue }
    if (-not [System.IO.Directory]::Exists($subDir)) { [System.IO.Directory]::CreateDirectory($subDir) | Out-Null }
    Write-FileHeader $folder $imgUrls.Count $vidUrls.Count

    # ---- 图片：只登记，循环结束后统一进全局并发池 ----
    if (-not $VideosOnly) {
        $items = @()
        $i = 1
        foreach ($u in $imgUrls) {
            $name = "{0:D4}" -f $i
            $exist = Get-ChildItem -LiteralPath $subDir -Filter "$name.*" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($exist -and (Test-ImageOk $exist.FullName)) {
                $gImgSkip++
                if (-not $Quiet) { Write-Host ("   [img {0,3}/{1}] SKIP  {2}" -f $i, $imgUrls.Count, $exist.Name) -ForegroundColor DarkGray }
            } else {
                if ($exist) { Remove-Item -LiteralPath $exist.FullName -Force }   # 截断/损坏 → 重下
                $items += @{ Url = $u; Base = (Join-Path $subDir $name); Idx = $i; Key = $folder }
                $script:ImgKeyByUrl[$u] = $folder
            }
            $i++
        }
        if ($items.Count -gt 0) {
            $script:ImgItems += $items
            Write-Host ("   [img] 登记 {0} 张 -> 全局图片池" -f $items.Count) -ForegroundColor DarkCyan
        }
    }

    # ---- 视频：登记待下载任务，分片进入全局并发池（循环结束后统一下载） ----
    if (-not $ImagesOnly) {
        $v = 1
        foreach ($m in $vidUrls) {
            $outName = "video_{0:D2}.ts" -f $v
            $mp4Name = "video_{0:D2}.mp4" -f $v
            $outFile = Join-Path $subDir $outName
            $mp4File = Join-Path $subDir $mp4Name
            # 续传判据：mp4 已存在即完成；ts 只是中间件
            if ([System.IO.File]::Exists($mp4File) -and (Get-Item -LiteralPath $mp4File).Length -gt 0) {
                $gVidSkip++
                if (-not $Quiet) { Write-Host ("   [vid {0,2}/{1}] SKIP  {2}" -f $v, $vidUrls.Count, $mp4Name) -ForegroundColor DarkGray }
            } else {
                if ([System.IO.File]::Exists($outFile)) { Remove-Item -LiteralPath $outFile -Force }   # 残留 ts → 重下
                # 登记阶段不抓 m3u8：避免启动期请求突发触发源站分钟级冷却（曾导致子进程全灭）；
                # m3u8 由子进程按需获取
                $script:VideoMetas += @{ Key=("f{0}-v{1}" -f $fi, $v); Folder=$folder; Ts=$outFile; Mp4=$mp4File; Mp4Name=$mp4Name; Url=$m; SegCount=0 }
                Write-Host ("   [vid {0,2}/{1}] 排队 -> 子进程串行下载" -f $v, $vidUrls.Count) -ForegroundColor Cyan
            }
            $v++
        }
    }
}

# ---------- 图片：全局并发池（跳项目一次性满窗下载） ----------
# 旧做法每个项目单独一批：小批次末尾几张慢图会让 48 条连接大部分闲置（实测 31 张批 1.0MB/s vs 254 张批 2.2MB/s）
if ($script:ImgItems.Count -gt 0) {
    # 全局池中 Idx 必须唯一：它既是完成去重/计数依据也是进度序号，
    # 沿用各项目内的 1..N 会跳项目撞键，导致完成事件被误判为“已处理”而永不计数（曾使进度冻结在 60/2458）
    $uid = 0
    foreach ($it in $script:ImgItems) { $uid++; $it.Idx = $uid }
    Write-Banner ("图片全局并发: {0} 张 / 并发 x{1}" -f $script:ImgItems.Count, $script:Degree)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $res = Invoke-FastDownload $script:ImgItems $script:Degree 'img'
    $sw.Stop()
    $sumB = 0; $okN = 0
    foreach ($e in $res) {
        if ($e.Ok) {
            $gImgOK++; $okN++; $sumB += $e.Bytes
        } else {
            $gImgFail++
            $fk = $script:ImgKeyByUrl[$e.Url]
            if ($fk -and $stat.Contains($fk)) { $stat[$fk].fails += $e.Url }
        }
    }
    $mb = [math]::Round($sumB/1MB,1)
    $sec = [math]::Max(0.1, $sw.Elapsed.TotalSeconds)
    Write-Host ("   [img] 全局完成 {0}/{1} 张 / {2} MB / {3}s  =>  {4} MB/s" -f $okN, $res.Count, $mb, [math]::Round($sec,1), [math]::Round($mb/$sec,1)) -ForegroundColor Cyan
}

# ---------- 视频：进程级并行（每视频一个子进程，进程内串行下载） ----------
# 子进程内串行 = 可靠模式；父进程并行 N 个视频 = 提速；
# 任一子进程挂死可被 deadline 杀掉，不拖累全局（runspace 异步方案在 PS5.1 下会无超时挂起）
if ($script:VideoMetas.Count -gt 0) {
    $worker = Join-Path $Cfg.ProjectDir 'download_video_worker.ps1'
    $parallel = [math]::Max(1, $SegDegree)
    Write-Banner ("视频进程级并行: {0} 个视频 / 同时 {1} 个进程 (进程内串行)" -f $script:VideoMetas.Count, $parallel)
    $procs = @()
    $qi = 0
    $vDone = 0
    $coolUntil = [DateTime]::Now
    $lastBeat = [DateTime]::Now
    while ($qi -lt $script:VideoMetas.Count -or $procs.Count -gt 0) {
        while ($qi -lt $script:VideoMetas.Count -and $procs.Count -lt $parallel -and [DateTime]::Now -ge $coolUntil) {
            $vm = $script:VideoMetas[$qi]
            Write-Host ("   [vid {0,2}/{1}] 启动: [{2}] {3}" -f ($qi+1), $script:VideoMetas.Count, $vm.Folder, $vm.Mp4Name) -ForegroundColor Cyan
            # 注意：Start-Process -ArgumentList 不自动加引号，含空格/中文的路径必须手动包裹
            $argList = @('-ExecutionPolicy','Bypass','-NoProfile','-File',"`"$worker`"",'-M3u8',"`"$($vm.Url)`"",'-TsOut',"`"$($vm.Ts)`"",'-Mp4Out',"`"$($vm.Mp4)`"")
            $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -NoNewWindow -PassThru
            $procs += [psobject]@{ P=$p; Vm=$vm; Start=[DateTime]::Now }
            $qi++
        }
        Start-Sleep -Milliseconds 600
        $alive = @()
        foreach ($pr in $procs) {
            if ($pr.P.HasExited) {
                $vDone++
                $pr.P.Refresh()
                # 成功判据以 mp4 是否落地为准（ExitCode 在未 Refresh 时不可靠）
                $mp4Ok = [System.IO.File]::Exists($pr.Vm.Mp4) -and (Get-Item -LiteralPath $pr.Vm.Mp4).Length -gt 0
                if ($mp4Ok -or $pr.P.ExitCode -eq 0) {
                    $gVidOK++
                    $mb = 0; if ([System.IO.File]::Exists($pr.Vm.Mp4)) { $mb = [math]::Round((Get-Item -LiteralPath $pr.Vm.Mp4).Length/1MB,1) }
                    Write-Host ("   [vid {0,2}/{1}] 完成: [{2}] {3}  ({4} MB)" -f $vDone, $script:VideoMetas.Count, $pr.Vm.Folder, $pr.Vm.Mp4Name, $mb) -ForegroundColor Green
                } else {
                    $gVidFail++
                    $stat[$pr.Vm.Folder].fails += $pr.Vm.Url
                    # 失败后全局冷却 60s 再放新任务，避免连续撞冷却期
                    $coolUntil = [DateTime]::Now.AddSeconds(60)
                    Write-Host ("   [vid {0,2}/{1}] 失败: [{2}] {3}  (exit {4}) -> 冷却 60s" -f $vDone, $script:VideoMetas.Count, $pr.Vm.Folder, $pr.Vm.Mp4Name, $pr.P.ExitCode) -ForegroundColor Red
                }
                $pr.P.Dispose()
            } elseif (([DateTime]::Now - $pr.Start).TotalMinutes -gt 25) {
                try { $pr.P.Kill() } catch {}
                $vDone++
                $gVidFail++
                $stat[$pr.Vm.Folder].fails += $pr.Vm.Url
                Write-Host ("   [vid {0,2}/{1}] 超时kill: [{2}] {3}" -f $vDone, $script:VideoMetas.Count, $pr.Vm.Folder, $pr.Vm.Mp4Name) -ForegroundColor Red
                $pr.P.Dispose()
            } else {
                $alive += $pr
            }
        }
        $procs = $alive
        if (([DateTime]::Now - $lastBeat).TotalSeconds -ge 15) {
            $lastBeat = [DateTime]::Now
            Write-Host ("   .. 视频进度 {0}/{1}  (运行中进程 {2})" -f $vDone, $script:VideoMetas.Count, $procs.Count) -ForegroundColor DarkCyan
        }
    }
}

# ---------- 汇总 ----------
if ($ListOnly) {
    Write-Banner "统计结果 (ListOnly)"
    foreach ($k in $stat.Keys) {
        Write-Host ("  {0}   图片 {1} | 视频 {2}" -f $k, $stat[$k].imgExp, $stat[$k].vidExp)
    }
    $ti = 0; $tv = 0; foreach ($k in $stat.Keys) { $ti += $stat[$k].imgExp; $tv += $stat[$k].vidExp }
    Write-Host ("  合计: 图片 {0} | 视频 {1}" -f $ti, $tv) -ForegroundColor Cyan
    exit
}

# 统计落地情况
foreach ($k in $stat.Keys) {
    $sub = Join-Path $Root $k
    $ig = 0; $vg = 0; $mb = 0.0
    if ([System.IO.Directory]::Exists($sub)) {
        $all = @(Get-ChildItem -LiteralPath $sub -File)
        $ig  = @($all | Where-Object { $_.Extension -match '\.(jpg|jpeg|png|gif|webp)$' }).Count
        $vd  = @($all | Where-Object { $_.Extension -eq '.mp4' -and $_.Length -gt 0 })
        $vg  = $vd.Count
        if ($vd.Count) { $mb = [math]::Round((($vd | Measure-Object Length -Sum).Sum)/1MB,1) }
    }
    $stat[$k].imgGot = $ig; $stat[$k].vidGot = $vg; $stat[$k].mb = $mb
}

Write-Banner "汇总报表"
Write-Host ("  {0,-46} {1,10} {2,10} {3,10}" -f '项目', '图片', '视频', '视频MB') -ForegroundColor White
Write-Host ("  " + ('-' * 76)) -ForegroundColor DarkGray
$tig=$tvg=0; $tmb=0.0
foreach ($k in $stat.Keys) {
    $s = $stat[$k]
    $imgTxt = "{0}/{1}" -f $s.imgGot, $s.imgExp
    $vidTxt = "{0}/{1}" -f $s.vidGot, $s.vidExp
    Write-Host ("  {0,-46} {1,10} {2,10} {3,10}" -f $k, $imgTxt, $vidTxt, $s.mb)
    $tig += $s.imgGot; $tvg += $s.vidGot; $tmb += $s.mb
}
Write-Host ("  " + ('-' * 76)) -ForegroundColor DarkGray
Write-Host ("  本次: 图片 OK {0} / SKIP {1} / FAIL {2} | 视频 OK {3} / SKIP {4} / FAIL {5} | 分片 {6}" -f $gImgOK,$gImgSkip,$gImgFail,$gVidOK,$gVidSkip,$gVidFail,$gSeg) -ForegroundColor Cyan
Write-Host ("  落地: 图片 {0} | 视频 {1} | 视频合计 {2} MB" -f $tig, $tvg, [math]::Round($tmb)) -ForegroundColor Cyan

# 失败清单
$anyFail = $false
foreach ($k in $stat.Keys) {
    if ($stat[$k].fails.Count -gt 0) {
        if (-not $anyFail) { Write-Banner "失败/缺失清单"; $anyFail = $true }
        Write-Host ("  [" + $k + "]") -ForegroundColor Yellow
        foreach ($u in $stat[$k].fails) { Write-Host ("     - " + $u) -ForegroundColor Red }
    }
}
if (-not $anyFail) { Write-Host "`n  无失败项。" -ForegroundColor Green }
Write-Host ""
if (-not $NoProgress) {
    Write-Progress -Id 1 -Activity 'Overall' -Completed
    Write-Progress -Id 2 -Activity 'Images' -Completed -ErrorAction SilentlyContinue
    Write-Progress -Id 3 -Activity 'Videos' -Completed -ErrorAction SilentlyContinue
}

if ($ToMp4) { Convert-Videos }
Close-Log
