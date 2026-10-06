# =============================================================================
#  config.ps1 —— 全项目唯一的路径/参数真值源
#  所有脚本通过  . (Join-Path $PSScriptRoot 'config.ps1')  引入（tools\ 与 web\ 下引上级）
#  本文件只放**中性参数**（可公开）；上游地址、探测主机、被屏蔽 URL、本机绝对路径
#  一律放在 config.local.ps1（已被 .gitignore 排除，模板见 config.local.example.ps1）。
#  项目可整体搬迁（根目录由 $PSScriptRoot 自动推导）
# =============================================================================

$ProjectDir = $PSScriptRoot

$Cfg = [ordered]@{
    # ---- 目录 ----
    ProjectDir  = $ProjectDir
    RepoDir     = (Join-Path $ProjectDir 'repo')        # git clone 工作副本（上游原样，勿手改）
    BaselineDir = (Join-Path $ProjectDir 'repo_html')   # 已处理 HTML 基线（带日期名）= 比对资料
    ToolsDir    = (Join-Path $ProjectDir 'tools')
    StateDir    = (Join-Path $ProjectDir 'state')
    LogDir      = (Join-Path $ProjectDir 'logs')

    # ---- 产物输出根目录（图片与视频同放一个项目文件夹）----
    # 真实路径由 config.local.ps1 提供；环境变量 GALLERY_OUT 优先级最高
    OutDir      = $(if ($env:GALLERY_OUT) { $env:GALLERY_OUT } else { (Join-Path (Split-Path -Parent $ProjectDir) 'gallery-out') })

    # ---- 状态文件 ----
    Manifest    = (Join-Path $ProjectDir 'state\manifest.csv')   # hash,datedName,date,imgExp,vidExp,firstSeen,lastProcessed,gkey
    PendingFile = (Join-Path $ProjectDir 'state\pending.txt')    # 待处理项目（基线名，每行一个，不含 .html）
    DeadLinks   = (Join-Path $ProjectDir 'state\deadlinks.txt')  # 已实地探测确认 4xx 的源 URL，审计时豁免

    # ---- 上游仓库（实际地址在 config.local.ps1）----
    RepoUrl     = ''

    # ---- 网络自检目标（实际主机在 config.local.ps1）：K=稳定键名 repo/img/list/seg ----
    NetTargets  = @()

    # ---- 过滤规则 ----
    BlockM3u8   = @()                       # 永不下载的 URL（实际值在 config.local.ps1）
    ExcludeHtml = @('tiquqi.html')          # 工具页，非内容
    ExcludeHtmlWildcard = @('google*')      # 站点验证文件等

    # ---- 下载并发参数（实测结论，勿盲目调高）----
    Degree      = 48    # 图片全局并发；48 已能吃满图床（约 3 MB/s），再加无收益
    SegDegree   = 2     # 视频并行进程数；源站每主机仅容忍约 1 条流，2 为实测可靠上限
}

# ---- 本机/来源专属参数（不存在则用上面的中性默认值；模板见 config.local.example.ps1）----
# 必须在“建目录”与“$Rx/$Cfg 后续使用”之前 dot-source，因为它会覆盖 OutDir。
$LocalCfg = Join-Path $ProjectDir 'config.local.ps1'
if ([System.IO.File]::Exists($LocalCfg)) {
    . $LocalCfg
    if ($env:GALLERY_OUT) { $Cfg['OutDir'] = $env:GALLERY_OUT }   # 环境变量优先级最高
}

# 确保运行期目录存在
foreach ($k in @('RepoDir','BaselineDir','ToolsDir','StateDir','LogDir')) {
    if (-not [System.IO.Directory]::Exists($Cfg[$k])) { [System.IO.Directory]::CreateDirectory($Cfg[$k]) | Out-Null }
}
if (-not [System.IO.Directory]::Exists($Cfg.OutDir)) { [System.IO.Directory]::CreateDirectory($Cfg.OutDir) | Out-Null }

# ---- 共用正则（内容解析规则，全项目一致）----
$Rx = @{
    ImgContainer = [regex]'<div class="img-container">[\s\S]*?<img\s+src="([^"]+)"'
    BareImg      = [regex]'<img\s+src="([^"]+)"'
    M3u8         = [regex]'https?://[^"''<>\s]+?\.m3u8'
    OgTitle      = [regex]'<meta\s+property="og:title"\s+content="([^"]*)"'
    NoteTitle    = [regex]'<h2\s+class="note-title"[^>]*>([\s\S]*?)</h2>'
    NoteTime     = [regex]'<time\s+class="note-time"[^>]*>\s*(\d{4})-(\d{2})-(\d{2})'
}

# 从 HTML 内容解析 (标题, 日期, 图片URL[], 视频URL[])
function Parse-Gallery {
    param([string]$Text)
    $title = ''
    $m = $Rx.OgTitle.Match($Text)
    if ($m.Success) { $title = $m.Groups[1].Value }
    if (-not $title) {
        $m2 = $Rx.NoteTitle.Match($Text)
        if ($m2.Success) { $title = ($m2.Groups[1].Value -replace '<[^>]+>','').Trim() }
    }
    $title = [System.Net.WebUtility]::HtmlDecode($title).Trim()
    $date = ''
    $mt = $Rx.NoteTime.Match($Text)
    if ($mt.Success) { $date = ('{0}-{1}-{2}' -f $mt.Groups[1].Value.Substring(2), $mt.Groups[2].Value, $mt.Groups[3].Value) }

    $imgs = @($Rx.ImgContainer.Matches($Text) | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    if ($imgs.Count -eq 0) { $imgs = @($Rx.BareImg.Matches($Text) | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) }
    $vids = @($Rx.M3u8.Matches($Text) | ForEach-Object { $_.Value } | Select-Object -Unique |
              Where-Object { $Cfg.BlockM3u8 -notcontains $_ })

    return [pscustomobject]@{ Title=$title; Date=$date; Imgs=$imgs; Vids=$vids }
}

# 由标题+日期生成合法文件夹/文件名（非法字符 -> _）
function Make-SafeName {
    param([string]$Title, [string]$Date)
    $t = ($Title -replace '[\\/:*?"<>|]', '_').Trim()
    if (-not $t) { $t = 'untitled' }
    if ($Date) { return ('[{0}]{1}' -f $Date, $t) } else { return $t }
}

# 内容哈希：先规范化（去 BOM、CRLF→LF）再算 SHA256
# 必需：git 的 core.autocrlf 会把仓库文件转成 CRLF，直接按字节哈希会把全部基线误判为“内容变更”
function Get-ContentHash {
    param([byte[]]$Bytes)
    $txt = [System.Text.Encoding]::UTF8.GetString($Bytes)
    if ($txt.Length -gt 0 -and $txt[0] -eq [char]0xFEFF) { $txt = $txt.Substring(1) }
    $txt = $txt -replace "`r`n", "`n"
    $norm = [System.Text.Encoding]::UTF8.GetBytes($txt)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return (([System.BitConverter]::ToString($sha.ComputeHash($norm)) -replace '-','').ToLower())
}

# 画廊内容签名：标题 + 日期 + 图片URL序列 + 视频URL序列
# 【判重必须用它，不能只用整页字节哈希】上游经常把同一个画廊重复投稿成第二个 HTML 文件
# （换文件名，或页面有无关紧要的字节差异，例如开头多一个空行）；只按字节哈希判重会把这种
# 重复投稿当成“同名内容更新”，于是新建 xxx(2) 项目并把同一批图片/视频完整重下一遍。
function Get-GalleryKeyFromParsed {
    param($g)   # Parse-Gallery 的返回对象（已解析一次时可直接复用，避免反复正则）
    $sig = ($g.Title + '|' + $g.Date + '|I:' + ($g.Imgs -join ',') + '|V:' + ($g.Vids -join ','))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return (([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sig))) -replace '-','').ToLower())
}

function Get-GalleryKey {
    param([string]$Text)
    return Get-GalleryKeyFromParsed (Parse-Gallery $Text)
}

# 按文件路径算签名（便捷封装，避免调用方各写一遍读文件+解析）
function Get-GalleryKeyByFile {
    param([string]$Path)
    return Get-GalleryKey ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8))
}

# 网络/TLS 基线设置（每个进程调用一次）
function Set-NetBaseline {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    [System.Net.ServicePointManager]::DefaultConnectionLimit = 128
    [System.Net.ServicePointManager]::Expect100Continue = $false
}
