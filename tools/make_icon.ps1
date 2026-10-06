<#
.SYNOPSIS
    由一张方图/近方图生成 Windows 多尺寸 .ico（PNG 负载）与网页 favicon.png。
.DESCRIPTION
    为什么用脚本而不是手边工具：PS 5.1 自带的 System.Drawing 就能做高质量缩放，
    ICO 又允许直接塞 PNG 负载（Vista 起支持），所以不必引入任何外部依赖。

    做法：居中裁成正方 -> 按目标边长 HighQualityBicubic 缩放 -> 存 PNG 字节 ->
    拼 ICONDIR + ICONDIRENTRY[] + 各尺寸 PNG。256x256 在目录项里宽高写 0（规范如此）。

    用法：
      powershell -File tools\make_icon.ps1 -Source 某图.jpg
        -> web\assets\icon-src.jpg（源图副本）+ web\assets\app.ico + web\public\favicon.png
      换图：再跑一次（覆盖生成物），然后重跑一次“创建桌面快捷方式”即可。
      项目整体搬迁后 .lnk 里的绝对路径会失效，重新点一次页面上的“创建桌面快捷方式”。
#>
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [string]$Out = '',
    [string]$CopySource = '',
    [string]$Favicon = '',
    [int[]]$Sizes = @(16, 24, 32, 48, 64, 128, 256)
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8

if (-not [System.IO.File]::Exists($Source)) { throw "找不到源图：$Source" }
if (-not $Out)      { $Out      = Join-Path $ProjectRoot 'web\assets\app.ico' }
if (-not $Favicon)  { $Favicon  = Join-Path $ProjectRoot 'web\public\favicon.png' }
foreach ($d in @([System.IO.Path]::GetDirectoryName($Out), [System.IO.Path]::GetDirectoryName($Favicon))) {
    if (-not [System.IO.Directory]::Exists($d)) { [System.IO.Directory]::CreateDirectory($d) | Out-Null }
}

Add-Type -AssemblyName System.Drawing
$img = [System.Drawing.Image]::FromFile($Source)
try {
    # 居中裁成正方：桌面图标必须是正方形，否则会被拉扁
    $side = [Math]::Min($img.Width, $img.Height)
    $sx = [int](($img.Width  - $side) / 2)
    $sy = [int](($img.Height - $side) / 2)

    function Render-PngBytes([System.Drawing.Image]$src, [int]$side, [int]$sx, [int]$sy, [int]$target) {
        $bmp = New-Object System.Drawing.Bitmap $target, $target, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            # 边缘不渗透明：先平铺边缘再绘制
            $g.DrawImage($src, (New-Object System.Drawing.Rectangle 0, 0, $target, $target),
                              (New-Object System.Drawing.Rectangle $sx, $sy, $side, $side),
                              [System.Drawing.GraphicsUnit]::Pixel)
        } finally { $g.Dispose() }
        $ms = New-Object System.IO.MemoryStream
        try { $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $bytes = $ms.ToArray() }
        finally { $ms.Dispose(); $bmp.Dispose() }
        # 必须用 `,@()` 把数组包一层：PowerShell 的输出流会把 byte[] 展开成单字节集合，
        # 调用方拿到的就是 Object[]，后面 List[byte].AddRange 直接报转换失败
        return , $bytes
    }

    # 注意：不能用 `$payloads += ,(byte[])` —— 数组拼接会把 byte[] 扫平，
    # 到下面 AddRange 时元素就成了 Object[]，报“无法转换为 IEnumerable[byte]”。用 List 存。
    $payloads = New-Object System.Collections.Generic.List[object]
    foreach ($s in ($Sizes | Sort-Object)) {
        $payloads.Add((Render-PngBytes $img $side $sx $sy $s))
    }
    $fav = Render-PngBytes $img $side $sx $sy 64
} finally { $img.Dispose() }

# ---- 拼 ICO：ICONDIR(6B) + N * ICONDIRENTRY(16B) + 负载
$dims = @($Sizes | Sort-Object)
$head = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($head)
$bw.Write([uint16]0)                 # reserved
$bw.Write([uint16]1)                 # type = icon
$bw.Write([uint16]$payloads.Count)   # 条目数
$offset = 6 + 16 * $payloads.Count
for ($i = 0; $i -lt $payloads.Count; $i++) {
    $dim = $dims[$i]
    $png = $payloads[$i]
    $bw.Write([byte]$(if ($dim -ge 256) { 0 } else { $dim }))   # width
    $bw.Write([byte]$(if ($dim -ge 256) { 0 } else { $dim }))   # height
    $bw.Write([byte]0)                                          # 调色板色数
    $bw.Write([byte]0)                                          # reserved
    $bw.Write([uint16]1)                                        # planes
    $bw.Write([uint16]32)                                       # bit count
    $bw.Write([uint32]$png.Length)                              # 负载字节数
    $bw.Write([uint32]$offset)                                  # 负载偏移
    $offset += $png.Length
}
$bw.Flush()
$all = New-Object System.Collections.Generic.List[byte]
$all.AddRange([byte[]] $head.ToArray())
foreach ($png in $payloads) { $all.AddRange([byte[]] $png) }
$bw.Dispose(); $head.Dispose()
[System.IO.File]::WriteAllBytes($Out, $all.ToArray())
[System.IO.File]::WriteAllBytes($Favicon, [byte[]] $fav)
if ($CopySource) {
    if (-not [System.IO.Path]::IsPathRooted($CopySource)) { $CopySource = Join-Path $ProjectRoot $CopySource }
    $dstDir = [System.IO.Path]::GetDirectoryName($CopySource)
    if (-not [System.IO.Directory]::Exists($dstDir)) { [System.IO.Directory]::CreateDirectory($dstDir) | Out-Null }
    [System.IO.File]::Copy($Source, $CopySource, $true)
}

Write-Host ("已生成图标: {0}（{1} 个尺寸：{2}）" -f $Out, $payloads.Count, (($Sizes | Sort-Object) -join '/'))
Write-Host ("已生成 favicon: {0}" -f $Favicon)
if ($CopySource) { Write-Host ("源图副本: {0}" -f $CopySource) }
