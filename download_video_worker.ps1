<#
.SYNOPSIS
    单视频下载 worker（子进程运行）：串行下载 HLS 分片 -> 拼接 ts -> ffmpeg 转 mp4。
.DESCRIPTION
    进程内串行 = 可靠；由父进程以多进程方式并行多个视频。退出码: 0=成功 1=失败
#>
param(
    [string]$M3u8,
    [string]$TsOut,
    [string]$Mp4Out
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
[System.Net.ServicePointManager]::DefaultConnectionLimit = 8
[System.Net.ServicePointManager]::Expect100Continue = $false

try {
    # m3u8 获取：重试 3 次，退避 10/30s，骑过源站冷却期
    $plist = $null
    for ($a = 1; $a -le 3; $a++) {
        try {
            $wc0 = New-Object System.Net.WebClient
            $wc0.Headers.Add('User-Agent', 'Mozilla/5.0')
            $plist = $wc0.DownloadString($M3u8)
            break
        } catch {
            Write-Host ("      m3u8 第{0}次失败: {1}" -f $a, $_.Exception.Message)
            if ($a -lt 3) { Start-Sleep -Seconds ((10, 30)[$a-1]) }
        }
    }
    if (-not $plist) { Write-Host 'VIDEO_FAIL'; exit 1 }
    $segs = @($plist -split "`r?`n" | Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') })
    if ($segs.Count -eq 0) { Write-Host "      无分片"; Write-Host 'VIDEO_FAIL'; exit 1 }

    $base = [System.Uri]$M3u8
    $fs = [System.IO.File]::Create($TsOut)
    $i = 1
    foreach ($sg in $segs) {
        $url = (New-Object System.Uri($base, $sg.Trim())).AbsoluteUri
        $ok = $false
        for ($a = 1; $a -le 5; $a++) {
            try {
                $wc = New-Object System.Net.WebClient
                $wc.Headers.Add('User-Agent', 'Mozilla/5.0')
                $b = $wc.DownloadData($url)
                $fs.Write($b, 0, $b.Length)
                $ok = $true
                Write-Host ("      seg {0,2}/{1} ok  {2,5} KB" -f $i, $segs.Count, [math]::Round($b.Length/1KB))
                break
            } catch {
                Write-Host ("      seg {0,2}/{1} 第{2}次失败: {3}" -f $i, $segs.Count, $a, $_.Exception.Message)
                if ($a -lt 5) { Start-Sleep -Seconds ((5, 15, 30, 60)[$a-1]) }
            }
        }
        if (-not $ok) {
            $fs.Close()
            Remove-Item -LiteralPath $TsOut -Force -ErrorAction SilentlyContinue
            Write-Host 'VIDEO_FAIL'
            exit 1
        }
        $i++
    }
    $fs.Close()

    & ffmpeg -hide_banner -loglevel error -y -i $TsOut -c copy $Mp4Out
    if ($LASTEXITCODE -eq 0 -and [System.IO.File]::Exists($Mp4Out)) {
        Remove-Item -LiteralPath $TsOut -Force
        Write-Host 'VIDEO_OK'
        exit 0
    } else {
        Write-Host 'VIDEO_FAIL_FFMPEG'
        exit 1
    }
} catch {
    Write-Host ('VIDEO_FAIL ' + $_.Exception.Message)
    exit 1
}
