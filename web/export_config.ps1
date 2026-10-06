<#
.SYNOPSIS
    把 config.ps1 的 $Cfg 导出成一行 JSON，供 web/server.mjs 启动时读取。
.DESCRIPTION
    存在的意义：路径/参数的唯一真值源仍然是 config.ps1（PROJECT.md §0 约定），Web 层不许另写一份
    路径常量。服务启动时调用本脚本拿一次，之后只读缓存。
    输出必须是 stdout 的唯一内容，所以这里只 Write 一行 JSON。
#>
$ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $ProjectRoot 'config.ps1')

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Utf8NoBom

$out = [ordered]@{
    projectDir  = [string]$Cfg.ProjectDir
    repoDir     = [string]$Cfg.RepoDir
    baselineDir = [string]$Cfg.BaselineDir
    stateDir    = [string]$Cfg.StateDir
    logDir      = [string]$Cfg.LogDir
    outDir      = [string]$Cfg.OutDir
    manifest    = [string]$Cfg.Manifest
    pendingFile = [string]$Cfg.PendingFile
    deadLinks   = [string]$Cfg.DeadLinks
    repoUrl     = [string]$Cfg.RepoUrl
    degree      = [int]$Cfg.Degree
    segDegree   = [int]$Cfg.SegDegree
    blockM3u8   = @($Cfg.BlockM3u8)
    psVersion   = $PSVersionTable.PSVersion.ToString()
}

[Console]::Out.Write((ConvertTo-Json -InputObject $out -Compress))
